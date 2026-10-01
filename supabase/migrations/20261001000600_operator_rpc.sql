-- 운영자 콘솔 RPC (docs/05 API #24·#29·#30·#31). 모두 security definer + 함수 안 운영자 검사, actor 는 auth.uid() 로 고정.

create or replace function require_operator(p_challenge uuid) returns void
  language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_challenge_operator(p_challenge) then
    raise exception 'operator only' using errcode = 'PT403';
  end if;
end $$;

-- 상태 전환(API #24): actor 위조 방지 래퍼
create or replace function transition_challenge_rpc(p_challenge_id uuid, p_to challenge_status) returns jsonb
  language plpgsql security definer set search_path = public as $$
begin
  perform require_operator(p_challenge_id);
  return transition_challenge(p_challenge_id, p_to, auth.uid(), now());
end $$;

-- 운영자 행동 감사 로그(규칙 게시·CSV 내려받기·사진 열람 등)
create or replace function log_operator_action(p_challenge_id uuid, p_action text, p_target jsonb default '{}') returns void
  language plpgsql security definer set search_path = public as $$
begin
  perform require_operator(p_challenge_id);
  if p_action !~ '^[a-z_]{3,40}$' then raise exception 'invalid action' using errcode = 'PT422'; end if;
  perform write_audit(p_challenge_id, auth.uid(), 'operator', p_action, coalesce(p_target, '{}'));
end $$;

-- 공지(API #29, N-03 scheduled): 참가자 전원(강퇴·탈퇴 제외)
create or replace function announce_challenge(p_challenge_id uuid, p_title text, p_body text) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare n int := 0; x record;
begin
  perform require_operator(p_challenge_id);
  if coalesce(trim(p_title), '') = '' or coalesce(trim(p_body), '') = '' then raise exception '제목과 본문을 입력해 주세요' using errcode = 'PT422'; end if;
  for x in select user_id from participants where challenge_id = p_challenge_id and status not in ('kicked', 'left') and user_id is not null
  loop
    perform enqueue_notification(x.user_id, p_challenge_id, 'N-03', p_title, p_body, jsonb_build_object('kind', 'announcement'));
    n := n + 1;
  end loop;
  perform write_audit(p_challenge_id, auth.uid(), 'operator', 'announce', jsonb_build_object('title', p_title, 'recipients', n));
  return jsonb_build_object('recipients', n);
end $$;

-- CSV 4종(API #30, 03 F-OP-04). 열 허용 목록만: health_alerts·operator_note·record_mode_reason 미포함.
create or replace function export_rows(p_challenge_id uuid, p_type text) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_operator(p_challenge_id);
  case p_type
    when 'ranking' then
      select coalesce(jsonb_agg(jsonb_build_object('rank', e ->> 'rank', 'nickname', e ->> 'nickname', 'cumulative_score', e ->> 'score')
        order by (e ->> 'rank')::int), '[]') into v
      from (select rows from leaderboard_snapshots where challenge_id = p_challenge_id and scope = 'cumulative'
            order by is_final desc, as_of desc limit 1) s, jsonb_array_elements(s.rows) e
      where not coalesce((e ->> 'aggregating')::boolean, false);
    when 'scores' then
      select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'local_date', d.local_date, 'bmr', d.bmr, 'a_d', d.a_d, 'i_d', d.i_d,
        'f_p', d.f_p, 'm_p', d.m_p, 'd_d', d.d_d, 's_d', d.s_d, 'main_meal_count', d.main_meal_count, 'is_counted', d.is_counted, 'is_final', d.is_final)
        order by p.nickname, d.local_date), '[]') into v
      from daily_scores d join participants p on p.id = d.participant_id where d.challenge_id = p_challenge_id;
    when 'meals' then
      select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'local_date', m.local_date, 'slot', m.slot, 'status', m.status,
        'ai_kcal', m.ai_kcal, 'confirmed_kcal', m.confirmed_kcal, 'delta_ratio', m.delta_ratio, 'engine', m.engine)
        order by p.nickname, m.local_date, m.slot), '[]') into v
      from meals m join participants p on p.id = m.participant_id where m.challenge_id = p_challenge_id;
    when 'activity' then
      select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'local_date', a.local_date, 'steps_total', a.steps_total,
        'steps_manual', a.steps_manual, 'floors', a.floors, 'steps_net_kcal', a.steps_net_kcal, 'sessions_net_kcal', a.sessions_net_kcal,
        'floors_kcal', a.floors_kcal, 'a_raw', a.a_raw, 'a_d', a.a_capped, 'platform_active_kcal_reference', a.platform_active_kcal)
        order by p.nickname, a.local_date), '[]') into v
      from daily_activity a join participants p on p.id = a.participant_id where a.challenge_id = p_challenge_id;
    else raise exception 'type: ranking|scores|meals|activity' using errcode = 'PT422';
  end case;
  perform write_audit(p_challenge_id, auth.uid(), 'operator', 'export_csv', jsonb_build_object('type', p_type));
  return v;
end $$;

-- 사진 파기(API #31): Archived(또는 Cancelled)만. 해시·메타는 남기고 원본 경로를 돌려준다(Storage 삭제는 Edge Function).
create or replace function purge_challenge_photos(p_challenge_id uuid) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare ch challenges; v_paths text[];
begin
  perform require_operator(p_challenge_id);
  select * into ch from challenges where id = p_challenge_id for update;
  if ch.status not in ('archived', 'cancelled') then raise exception '종료(Archived) 뒤에 파기할 수 있어요' using errcode = 'PT422'; end if;
  with u as (
    update photos set purged_at = now() where challenge_id = p_challenge_id and purged_at is null returning storage_path
  ) select coalesce(array_agg(storage_path), '{}') into v_paths from u;
  update challenges set photos_purged_at = now() where id = p_challenge_id;
  perform write_audit(p_challenge_id, auth.uid(), 'operator', 'purge_photos', jsonb_build_object('count', cardinality(v_paths)));
  return jsonb_build_object('count', cardinality(v_paths), 'paths', to_jsonb(v_paths), 'purged_at', now());
end $$;

revoke execute on function require_operator(uuid), transition_challenge_rpc(uuid, challenge_status), log_operator_action(uuid, text, jsonb),
  announce_challenge(uuid, text, text), export_rows(uuid, text), purge_challenge_photos(uuid) from public, anon;
grant execute on function transition_challenge_rpc(uuid, challenge_status), log_operator_action(uuid, text, jsonb),
  announce_challenge(uuid, text, text), export_rows(uuid, text), purge_challenge_photos(uuid) to authenticated, service_role;
grant execute on function require_operator(uuid) to service_role;
-- 직접 전환 호출은 래퍼로만
revoke execute on function transition_challenge(uuid, challenge_status, uuid, timestamptz) from authenticated;

-- Storage: 사진 비공개 버킷(Supabase 에서만 존재하는 storage 스키마)
do $$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public) values ('meal-photos', 'meal-photos', false) on conflict (id) do nothing;
  end if;
end $$;
