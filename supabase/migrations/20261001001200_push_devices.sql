-- 푸시 기기 등록 · 트랜잭션 알림 즉시 발송(05 devices, 03 §8 N-04·N-06)

-- ---------------------------------------------------------------- 기기 등록
-- 앱이 로그인·참가 뒤, 그리고 토큰·권한이 바뀔 때 부른다. p_device 는 앱이 기기에 저장해 둔 이전 반환값(없으면 null).
-- 같은 FCM 토큰이 다른 행(다른 계정으로 로그인했던 기록 포함)에 있으면 지워서, 한 기기에 두 사람 알림이 가지 않게 한다.
create or replace function register_device(p_device uuid, p_platform text, p_token text,
  p_permission push_permission, p_app_version text default null) returns uuid
  language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_token text := nullif(btrim(coalesce(p_token, '')), '');
begin
  if v_uid is null then raise exception '로그인이 필요해요' using errcode = 'PT403'; end if;
  if not exists (select 1 from users where id = v_uid) then
    raise exception '참가 정보가 없어요' using errcode = 'PT404';
  end if;
  if p_platform not in ('ios', 'android') then raise exception '지원하지 않는 기기예요' using errcode = 'PT422'; end if;
  select id into v_id from devices where id = p_device and user_id = v_uid;
  if v_token is not null then
    delete from devices where push_token = v_token and id is distinct from v_id;
  end if;
  if v_id is null then
    insert into devices (user_id, platform, push_token, push_permission, app_version)
      values (v_uid, p_platform, v_token, p_permission, p_app_version)
      returning id into v_id;
  else
    update devices set platform = p_platform, push_token = v_token, push_permission = p_permission,
      app_version = coalesce(p_app_version, app_version), updated_at = now()
      where id = v_id;
  end if;
  return v_id;
end $$;
revoke execute on function register_device(uuid, text, text, push_permission, text) from public, anon;
grant execute on function register_device(uuid, text, text, push_permission, text) to authenticated, service_role;

-- ---------------------------------------------------------------- 알림 집기(공통)
-- 발송 워커(notify)는 예약 시각이 지난 것을 모아서, 분석 완료(N-04) 같은 트랜잭션 알림은 만든 직후 한 건만 집어 바로 보낸다.
-- 규칙은 하나: 토큰 없음·권한 미허용 → no_push, scheduled 하루 4건 초과 → daily_cap.
create or replace function claim_notifications(p_now timestamptz, p_limit int, p_only uuid)
  returns table (id uuid, user_id uuid, type notification_type, title text, body text, payload jsonb, push_tokens text[])
  language plpgsql as $$
declare
  n record;
  v_tokens text[];
  v_sent_today int;
begin
  for n in
    select x.* from notifications x
    where x.sent_at is null and x.skipped_reason is null and x.scheduled_at <= p_now
      and (p_only is null or x.id = p_only)
    order by x.scheduled_at
    limit p_limit
    for update skip locked
  loop
    select array_agg(d.push_token) into v_tokens from devices d
      where d.user_id = n.user_id and d.push_permission = 'granted' and d.push_token is not null;
    if v_tokens is null then
      update notifications set skipped_reason = 'no_push' where notifications.id = n.id;
      continue;
    end if;
    if n.category = 'scheduled' then
      select count(*) into v_sent_today from notifications s
        where s.user_id = n.user_id and s.category = 'scheduled' and s.sent_at is not null
          and kst_date(s.sent_at) = kst_date(p_now);
      if v_sent_today >= 4 then
        update notifications set skipped_reason = 'daily_cap' where notifications.id = n.id;
        continue;
      end if;
    end if;
    update notifications set sent_at = p_now where notifications.id = n.id;
    id := n.id; user_id := n.user_id; type := n.type; title := n.title; body := n.body; payload := n.payload; push_tokens := v_tokens;
    return next;
  end loop;
end $$;

create or replace function claim_due_notifications(p_now timestamptz default now(), p_limit int default 200)
  returns table (id uuid, user_id uuid, type notification_type, title text, body text, payload jsonb, push_tokens text[])
  language sql as $$
  select * from claim_notifications(p_now, p_limit, null)
$$;

create or replace function claim_notification(p_id uuid, p_now timestamptz default now())
  returns table (id uuid, user_id uuid, type notification_type, title text, body text, payload jsonb, push_tokens text[])
  language sql as $$
  select * from claim_notifications(p_now, 1, p_id)
$$;

revoke execute on function claim_notifications(timestamptz, int, uuid) from public, anon, authenticated;
revoke execute on function claim_notification(uuid, timestamptz) from public, anon, authenticated;
grant execute on function claim_notifications(timestamptz, int, uuid), claim_notification(uuid, timestamptz) to service_role;
