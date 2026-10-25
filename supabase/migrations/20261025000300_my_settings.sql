-- 설정 화면 토글을 서버에 저장한다(docs/02 D75). 앱을 다시 켜거나 다시 설치해도 서버 값을 읽는다.
--   알림 3종(어제 결과 N-01 · 저녁 리마인드 N-02 · 분석 완료 N-04): users.notify_* — 끈 종류는 발송 함수가 보내지 않는다(skipped_reason 'muted').
--     공지(N-03)·검토(N-05)·판정(N-06)·건강 안내(N-07)는 끌 수 없다(03 §8).
--   순위에 내 행 보이기 · 측정 등급 배지 공개: 기존 participants.leaderboard_visible · grade_badge_public 을 그대로 쓴다
--     (build_leaderboard 가 이미 따른다). 설정은 사용자 단위라 내 참가 행 전부에 쓰고, users 에도 남겨 새로 참가하는 챌린지가 이어받는다.
--   AI 사진 분석 동의: 기존 consents(overseas_ai). 철회하면 분석 전(captured) 내 끼니도 분석하지 않는다(engine = 'none').
-- 덧붙여 세션(challenge_session)에 이번 주 오늘 전 건너뜀 사용 수(skips_used_before)를 싣는다 — 앱 '건너뜀 (남은 n회)'.

alter table users
  add column notify_yesterday boolean not null default true,
  add column notify_reminder boolean not null default true,
  add column notify_analysis boolean not null default true,
  add column leaderboard_visible boolean not null default true,
  add column grade_badge_public boolean not null default false;

-- 지금까지 참가 행에 따로 저장된 값(운영 중 직접 바꾼 경우)을 사용자 설정으로 모은다: 하나라도 숨김이면 숨김, 하나라도 공개면 공개
update users u set leaderboard_visible = false
  where exists (select 1 from participants p where p.user_id = u.id and not p.leaderboard_visible and p.status not in ('kicked', 'left'));
update users u set grade_badge_public = true
  where exists (select 1 from participants p where p.user_id = u.id and p.grade_badge_public and p.status not in ('kicked', 'left'));

-- 새 참가 행은 내 공개 설정을 이어받는다(join_challenge 를 고치지 않고)
create or replace function participants_inherit_settings() returns trigger language plpgsql as $$
declare u users;
begin
  if new.user_id is not null then
    select * into u from users where id = new.user_id;
    if u.id is not null then
      new.leaderboard_visible := u.leaderboard_visible;
      new.grade_badge_public := u.grade_badge_public;
    end if;
  end if;
  return new;
end $$;
create trigger participants_inherit_settings before insert on participants
  for each row execute function participants_inherit_settings();

-- ---------------------------------------------------------------- 읽기·쓰기 RPC
create or replace function my_settings() returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); u users;
begin
  if v_uid is null then raise exception '로그인이 필요해요' using errcode = 'PT401'; end if;
  select * into u from users where id = v_uid;
  return jsonb_build_object(
    'notify_yesterday', coalesce(u.notify_yesterday, true),
    'notify_reminder', coalesce(u.notify_reminder, true),
    'notify_analysis', coalesce(u.notify_analysis, true),
    'leaderboard_visible', coalesce(u.leaderboard_visible, true),
    'grade_badge_public', coalesce(u.grade_badge_public, false),
    'ai_consent', exists (select 1 from consents c where c.user_id = v_uid and c.type = 'overseas_ai' and c.revoked_at is null));
end $$;

-- p: 바꿀 항목만(위 my_settings 의 키, 값은 true/false). 모르는 키·불리언이 아닌 값은 422. 반환: 바뀐 뒤의 my_settings().
create or replace function set_my_settings(p jsonb) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  k text;
  v_ver text;
begin
  if v_uid is null then raise exception '로그인이 필요해요' using errcode = 'PT401'; end if;
  if not exists (select 1 from users where id = v_uid) then raise exception '참가 정보가 없어요' using errcode = 'PT404'; end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception '설정 값이 올바르지 않아요' using errcode = 'PT422'; end if;
  for k in select jsonb_object_keys(p) loop
    if k not in ('notify_yesterday', 'notify_reminder', 'notify_analysis', 'leaderboard_visible', 'grade_badge_public', 'ai_consent')
       or jsonb_typeof(p -> k) <> 'boolean' then
      raise exception '설정 값이 올바르지 않아요' using errcode = 'PT422';
    end if;
  end loop;

  update users set
    notify_yesterday = coalesce((p ->> 'notify_yesterday')::boolean, notify_yesterday),
    notify_reminder = coalesce((p ->> 'notify_reminder')::boolean, notify_reminder),
    notify_analysis = coalesce((p ->> 'notify_analysis')::boolean, notify_analysis),
    leaderboard_visible = coalesce((p ->> 'leaderboard_visible')::boolean, leaderboard_visible),
    grade_badge_public = coalesce((p ->> 'grade_badge_public')::boolean, grade_badge_public),
    updated_at = now()
  where id = v_uid;

  if p ? 'leaderboard_visible' or p ? 'grade_badge_public' then
    update participants pt set
      leaderboard_visible = coalesce((p ->> 'leaderboard_visible')::boolean, pt.leaderboard_visible),
      grade_badge_public = coalesce((p ->> 'grade_badge_public')::boolean, pt.grade_badge_public),
      updated_at = now()
    where pt.user_id = v_uid;
  end if;

  if p ? 'ai_consent' then
    if (p ->> 'ai_consent')::boolean then
      if not exists (select 1 from consents where user_id = v_uid and type = 'overseas_ai' and revoked_at is null) then
        select c.version into v_ver from consents c where c.user_id = v_uid and c.type = 'overseas_ai' order by c.granted_at desc limit 1;
        insert into consents (user_id, type, version) values (v_uid, 'overseas_ai', coalesce(v_ver, 'v1'));
      end if;
    else
      update consents set revoked_at = now(), updated_at = now()
        where user_id = v_uid and type = 'overseas_ai' and revoked_at is null;
      -- 아직 분석하지 않은 사진은 국외 AI 로 보내지 않는다(analyze-meal 은 engine = 'none' 이면 건너뛴다). 앱은 검색으로 확정한다.
      update meals m set engine = 'none', updated_at = now()
        from participants pt
        where pt.id = m.participant_id and pt.user_id = v_uid and m.status = 'captured' and m.engine <> 'none';
    end if;
  end if;
  return my_settings();
end $$;

revoke execute on function my_settings(), set_my_settings(jsonb) from public, anon;
grant execute on function my_settings(), set_my_settings(jsonb) to authenticated, service_role;
revoke execute on function participants_inherit_settings() from public, anon, authenticated;

-- ---------------------------------------------------------------- 알림 집기: 끈 종류는 보내지 않는다
-- 규칙: 사용자가 끈 종류(N-01·N-02·N-04) → muted, 토큰 없음·권한 미허용 → no_push, scheduled 하루 4건 초과 → daily_cap.
create or replace function claim_notifications(p_now timestamptz, p_limit int, p_only uuid)
  returns table (id uuid, user_id uuid, type notification_type, title text, body text, payload jsonb, push_tokens text[])
  language plpgsql as $$
declare
  n record;
  u users;
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
    select * into u from users where users.id = n.user_id;
    if (n.type = 'N-01' and u.notify_yesterday is false)
       or (n.type = 'N-02' and u.notify_reminder is false)
       or (n.type = 'N-04' and u.notify_analysis is false) then
      update notifications set skipped_reason = 'muted' where notifications.id = n.id;
      continue;
    end if;
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
revoke execute on function claim_notifications(timestamptz, int, uuid) from public, anon, authenticated;
grant execute on function claim_notifications(timestamptz, int, uuid) to service_role;

-- ---------------------------------------------------------------- 세션: 이번 주 건너뜀 사용 수
-- 서버 점수 계산과 같은 skips_used_before(오늘 전, 같은 주 월~일, 하루·주 상한). 오늘 건너뜀은 앱이 오늘 끼니로 센다.
create or replace function challenge_session(p_challenge uuid) returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'today', kst_date(),
    'challenge', jsonb_build_object('id', c.id, 'name', c.name, 'kind', c.kind, 'status', c.status, 'start_date', c.start_date,
      'end_date', c.end_date, 'capacity', coalesce(c.capacity, 0), 'invite_code', c.invite_code, 'join_open', c.join_open,
      'rules_md', c.rules_md, 'published_at', c.published_at),
    'joined', (select count(*) from participants x where x.challenge_id = c.id and x.status not in ('kicked', 'left')),
    'rules', to_jsonb(r) - 'challenge_id' - 'created_at' - 'updated_at',
    'participant', jsonb_build_object('id', p.id, 'nickname', p.nickname, 'sex', p.sex, 'birth_year', p.birth_year, 'age', p.age,
      'height_cm', p.height_cm, 'weight_locked', p.weight_locked, 'bmr_locked', p.bmr_locked, 'status', p.status,
      'rank_eligible', p.rank_eligible, 'leaderboard_visible', p.leaderboard_visible, 'grade_badge_public', p.grade_badge_public,
      'warning_count', p.warning_count, 'last_synced_at', p.last_synced_at, 'last_sync_source', p.last_sync_source,
      'check_start', p.check_start, 'joined_at', p.joined_at),
    'stats', participant_rank_stats(p.id, kst_date() - 1),
    'skips_used_this_week', skips_used_before(p.id, kst_date(), engine_rules(c.id)),
    'notice', (select jsonb_build_object('title', n.title, 'body', n.body, 'created_at', n.created_at) from notifications n
      where n.user_id = p.user_id and n.challenge_id = c.id and n.type = 'N-03' order by n.created_at desc limit 1))
  from participants p
  join challenges c on c.id = p.challenge_id
  left join challenge_rules r on r.challenge_id = c.id
  where p.user_id = auth.uid() and p.challenge_id = p_challenge and p.status not in ('kicked', 'left')
$$;
