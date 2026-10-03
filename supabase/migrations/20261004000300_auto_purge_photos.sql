-- 사진 원본 자동 파기(docs/02 D56). Archived·취소는 즉시, 아니면 종료일+30일(KST, 상태 무관).
-- 공유 사진(D52)은 그 사진을 쓰는 다른 챌린지가 모두 파기 대상이 될 때 파기한다. 해시·메타는 남기고(photos.purged_at),
-- Storage 객체는 Edge Function 이 지운다(운영자: purge-photos, 매일 03:30 KST: purge-due).

-- 파기 대상 판정(한 곳). p_today 는 KST 날짜.
create or replace function photo_purge_eligible(c challenges, p_today date) returns boolean
  language sql stable as $$
  select c.status in ('archived', 'cancelled') or coalesce(c.end_date <= p_today - 30, false)
$$;

-- 파기 본체(검사 없음). 이 챌린지 사진과 이 챌린지 끼니(복사본 포함)가 쓰는 사진 중,
-- 아직 파기 대상이 아닌 다른 챌린지의 끼니가 쓰지 않는 것만 파기한다.
-- system 호출이 0건이면 감사 로그를 남기지 않고, 이미 기록된 photos_purged_at 도 건드리지 않는다.
create or replace function purge_photos_core(p_challenge_id uuid, p_actor uuid, p_role text, p_today date default kst_date())
  returns jsonb language plpgsql security definer set search_path = public as $$
declare v_paths text[]; v_quiet boolean;
begin
  with target as (
    select ph.id from photos ph
    where ph.purged_at is null
      and (ph.challenge_id = p_challenge_id
        or exists (select 1 from meals m where m.photo_id = ph.id and m.challenge_id = p_challenge_id))
      and not exists (select 1 from meals m join challenges c on c.id = m.challenge_id
        where m.photo_id = ph.id and m.challenge_id <> p_challenge_id and not photo_purge_eligible(c, p_today))
  ), u as (
    update photos set purged_at = now() from target t where photos.id = t.id and photos.purged_at is null returning photos.storage_path
  ) select coalesce(array_agg(storage_path), '{}') into v_paths from u;
  v_quiet := p_role = 'system' and cardinality(v_paths) = 0;
  update challenges set photos_purged_at = now() where id = p_challenge_id and (not v_quiet or photos_purged_at is null);
  if not v_quiet then
    perform write_audit(p_challenge_id, p_actor, p_role, 'purge_photos', jsonb_build_object('count', cardinality(v_paths)));
  end if;
  return jsonb_build_object('count', cardinality(v_paths), 'paths', to_jsonb(v_paths), 'purged_at', now());
end $$;

-- 사진 파기(API #31): 운영자. 파기 대상(Archived·취소·종료+30일)만.
create or replace function purge_challenge_photos(p_challenge_id uuid) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare ch challenges;
begin
  perform require_operator(p_challenge_id);
  select * into ch from challenges where id = p_challenge_id for update;
  if not photo_purge_eligible(ch, kst_date()) then raise exception '종료(Archived) 뒤에 파기할 수 있어요' using errcode = 'PT422'; end if;
  return purge_photos_core(p_challenge_id, auth.uid(), 'operator');
end $$;

-- 자동 파기(매일 03:30 KST, Edge purge-due). photos_purged_at 이 이미 있어도 다른 챌린지가 파기 대상이 되어
-- 새로 풀린 공유 사진이 있을 수 있어 다시 본다(본체는 purged_at is null 사진만 고른다).
create or replace function purge_due_photos(p_now timestamptz default now()) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare v_today date := kst_date(p_now); c challenges; r jsonb; n int := 0; v_count int := 0; v_paths jsonb := '[]';
begin
  for c in
    select * from challenges ch
    where photo_purge_eligible(ch, v_today)
      and (ch.photos_purged_at is null
        or exists (select 1 from photos ph where ph.challenge_id = ch.id and ph.purged_at is null)
        or exists (select 1 from meals m join photos ph on ph.id = m.photo_id where m.challenge_id = ch.id and ph.purged_at is null))
    order by ch.end_date, ch.id
    for update of ch
  loop
    r := purge_photos_core(c.id, null, 'system', v_today);
    n := n + 1;
    v_count := v_count + (r ->> 'count')::int;
    v_paths := v_paths || (r -> 'paths');
  end loop;
  return jsonb_build_object('challenges', n, 'count', v_count, 'paths', v_paths);
end $$;

revoke execute on function photo_purge_eligible(challenges, date), purge_photos_core(uuid, uuid, text, date),
  purge_due_photos(timestamptz) from public, anon, authenticated;
grant execute on function photo_purge_eligible(challenges, date), purge_photos_core(uuid, uuid, text, date),
  purge_due_photos(timestamptz) to service_role;

-- 스케줄: 03:30 KST(= 18:30 UTC) Edge purge-due 호출. pg_cron·pg_net·Vault 시크릿이 없으면(로컬 순수 Postgres 등) 건너뛴다.
-- 시크릿: select vault.create_secret('<https://ref.supabase.co>', 'challory_project_url');
--         select vault.create_secret('<CRON_SECRET>', 'challory_cron_secret');
do $do$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    return;
  end if;
  if to_regclass('vault.decrypted_secrets') is null then return; end if;
  if (select count(distinct name) from vault.decrypted_secrets where name in ('challory_project_url', 'challory_cron_secret')) < 2 then
    return;
  end if;
  execute 'create extension if not exists pg_cron';
  execute 'create extension if not exists pg_net';
  execute $c$select cron.schedule('challory-purge-photos', '30 18 * * *', $q$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'challory_project_url') || '/functions/v1/purge-due',
      headers := jsonb_build_object('content-type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'challory_cron_secret')),
      body := '{}'::jsonb, timeout_milliseconds := 30000)
  $q$)$c$;
end $do$;
