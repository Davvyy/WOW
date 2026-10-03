-- 참가·나가기·세션 RPC (docs/02 D47·D50)

-- 남은 기간으로 최소 참여일(최종 기준)을 채울 수 있는가: 오늘 참가하면 점검은 max(시작일, 오늘)부터 check_days 일
create or replace function join_feasible(p_ch challenges, p_today date) returns boolean
  language sql stable as $$
  select p_today <= p_ch.end_date
    and (p_ch.end_date - greatest(p_ch.start_date, p_today) + 1 - r.check_days)
      >= least(7, ((p_ch.end_date - p_ch.start_date + 1) - r.check_days) / 2)
  from (select (engine_rules(p_ch.id)).check_days as check_days) r
$$;
revoke execute on function join_feasible(challenges, date) from public, anon, authenticated;
grant execute on function join_feasible(challenges, date) to service_role;

-- 참가(05 API #3): 운영자 챌린지는 초대코드, 월간은 challenge_id. 모집·점검·진행 중 언제든(D47).
-- p: {code | challenge_id, nickname, sex, birth_year, height_cm, weight_kg, pregnancy?, eating_disorder?, auto_continue?,
--     consents:{terms, sensitive_health, overseas_ai}}
create or replace function join_challenge(p jsonb) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  ch challenges;
  v_age int; v_age_cons int; v_bmr int; v_bmi numeric;
  v_reason record_mode_reason;
  v_part participants;
  v_ver text := coalesce(p ->> 'consent_version', 'v1');
  v_active int;
begin
  if v_uid is null then raise exception 'login required' using errcode = 'PT401'; end if;
  if p ? 'challenge_id' then
    select * into ch from challenges where id = (p ->> 'challenge_id')::uuid and kind = 'monthly' for update;
  else
    select * into ch from challenges where invite_code = upper(p ->> 'code') for update;
  end if;
  if not found or ch.status not in ('recruiting', 'checking', 'running') then
    raise exception '코드를 다시 확인해 주세요' using errcode = 'PT404';
  end if;
  if not ch.join_open then raise exception '참가가 마감된 챌린지예요' using errcode = 'PT403'; end if;
  if not join_feasible(ch, kst_date(now())) then
    raise exception '남은 기간이 짧아 이번 챌린지에는 참가할 수 없어요. 다음 챌린지에서 만나요' using errcode = 'PT422';
  end if;
  if not coalesce((p #>> '{consents,terms}')::boolean, false) or not coalesce((p #>> '{consents,sensitive_health}')::boolean, false) then
    raise exception '필수 동의가 필요해요' using errcode = 'PT422';
  end if;
  if exists (select 1 from participants where challenge_id = ch.id and user_id = v_uid and block_rejoin) then
    raise exception '참가할 수 없는 챌린지예요' using errcode = 'PT403';
  end if;
  if ch.capacity is not null
     and (select count(*) from participants where challenge_id = ch.id and status not in ('kicked', 'left')) >= ch.capacity then
    raise exception '정원이 찼어요' using errcode = 'PT409';
  end if;
  -- 동시 참가 최대 3개(D47). 이미 이 챌린지에 참가 중이면 다시 참가(닉네임 갱신)로 본다.
  if not exists (select 1 from participants where challenge_id = ch.id and user_id = v_uid and status in ('active', 'record_mode', 'excluded')) then
    select count(*) into v_active from participants q join challenges c on c.id = q.challenge_id
      where q.user_id = v_uid and q.status in ('active', 'record_mode', 'excluded')
        and c.status in ('recruiting', 'checking', 'running', 'closing');
    if v_active >= 3 then raise exception '동시에 3개까지 참가할 수 있어요' using errcode = 'PT409'; end if;
  end if;

  v_age := extract(year from ch.start_date)::int - (p ->> 'birth_year')::int;        -- BMR 나이
  v_age_cons := v_age - 1;                                                           -- 12/31생 보수 판정
  if v_age_cons < 14 then raise exception '만 14세 이상부터 참가할 수 있어요' using errcode = 'PT422'; end if;
  v_bmi := (p ->> 'weight_kg')::numeric / power((p ->> 'height_cm')::numeric / 100, 2);
  v_reason := case
    when v_age_cons < 19 then 'minor'
    when v_bmi < 18.5 then 'bmi'
    when coalesce((p ->> 'pregnancy')::boolean, false) then 'pregnancy'
    when coalesce((p ->> 'eating_disorder')::boolean, false) then 'eating_disorder' end;
  v_bmr := bmr_kcal((p ->> 'sex')::sex_type, (p ->> 'weight_kg')::numeric, (p ->> 'height_cm')::numeric, v_age);

  insert into users (id, nickname) values (v_uid, p ->> 'nickname')
  on conflict (id) do update set nickname = excluded.nickname;
  insert into profiles (user_id, sex, birth_year, height_cm, weight_kg, bmr_age, record_mode, record_mode_reason, auto_continue)
  values (v_uid, (p ->> 'sex')::sex_type, (p ->> 'birth_year')::int, (p ->> 'height_cm')::numeric, (p ->> 'weight_kg')::numeric,
    v_age, v_reason is not null, v_reason, coalesce((p ->> 'auto_continue')::boolean, true))
  on conflict (user_id) do update set sex = excluded.sex, birth_year = excluded.birth_year, height_cm = excluded.height_cm,
    weight_kg = excluded.weight_kg, bmr_age = excluded.bmr_age, record_mode = excluded.record_mode, record_mode_reason = excluded.record_mode_reason,
    auto_continue = coalesce((p ->> 'auto_continue')::boolean, profiles.auto_continue);
  insert into consents (user_id, type, version)
  select v_uid, t::consent_type, v_ver from unnest(array['terms', 'sensitive_health']) t
  union all select v_uid, 'overseas_ai', v_ver where coalesce((p #>> '{consents,overseas_ai}')::boolean, false)
  on conflict (user_id, type, version) where revoked_at is null do nothing;

  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, status, rank_eligible)
  values (ch.id, v_uid, p ->> 'nickname', (p ->> 'sex')::sex_type, (p ->> 'birth_year')::int, v_age, (p ->> 'height_cm')::numeric,
    (p ->> 'weight_kg')::numeric, v_bmr, (case when v_reason is null then 'active' else 'record_mode' end)::participant_status, v_reason is null)
  on conflict (challenge_id, user_id) do update set nickname = excluded.nickname
  returning * into v_part;

  return jsonb_build_object('participant_id', v_part.id, 'challenge_id', ch.id, 'kind', ch.kind, 'check_start', v_part.check_start,
    'bmr', v_bmr, 'm_p', m_p(v_bmr, engine_rules(ch.id)), 'f_p', f_p(v_bmr, engine_rules(ch.id)), 'record_mode', v_reason is not null);
end $$;

-- 나가기(D50): 순위에서 빠지고 기록은 보관, 같은 챌린지 재참가 불가
create or replace function leave_challenge(p_challenge uuid) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); p participants; ch challenges;
begin
  if v_uid is null then raise exception 'login required' using errcode = 'PT401'; end if;
  select * into p from participants where challenge_id = p_challenge and user_id = v_uid for update;
  if p.id is null or p.status not in ('active', 'record_mode', 'excluded') then
    raise exception '참가 중인 챌린지가 아니에요' using errcode = 'PT404';
  end if;
  select * into ch from challenges where id = p_challenge;
  if ch.status not in ('recruiting', 'checking', 'running') then
    raise exception '마감된 챌린지는 나갈 수 없어요' using errcode = 'PT422';
  end if;
  update participants set status = 'left', rank_eligible = false, block_rejoin = true where id = p.id;
  perform write_audit(ch.id, v_uid, 'participant', 'participant_leave', jsonb_build_object('participant_id', p.id));
  return jsonb_build_object('participant_id', p.id, 'challenge_id', ch.id, 'status', 'left');
end $$;

-- 열린 월간 챌린지(코드 없이 참가): 참가 가능 여부와 내 참가 상태
create or replace function open_challenges() returns jsonb
  language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('challenge_id', c.id, 'name', c.name, 'kind', c.kind, 'status', c.status,
      'start_date', c.start_date, 'end_date', c.end_date, 'days', c.end_date - c.start_date + 1,
      'joined', (select count(*) from participants x where x.challenge_id = c.id and x.status not in ('kicked', 'left')),
      'joinable', join_feasible(c, kst_date()),
      'me', (select x.status from participants x where x.challenge_id = c.id and x.user_id = auth.uid()))
    order by c.start_date), '[]')
  from challenges c where c.kind = 'monthly' and c.status in ('recruiting', 'checking', 'running') and c.join_open
$$;

-- 챌린지별 앱 세션(05 API #33 확장): 요약 + 규칙 상수 + 내 참가 정보 + 순위 통계 + 최근 공지
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
    'notice', (select jsonb_build_object('title', n.title, 'body', n.body, 'created_at', n.created_at) from notifications n
      where n.user_id = p.user_id and n.challenge_id = c.id and n.type = 'N-03' order by n.created_at desc limit 1))
  from participants p
  join challenges c on c.id = p.challenge_id
  left join challenge_rules r on r.challenge_id = c.id
  where p.user_id = auth.uid() and p.challenge_id = p_challenge and p.status not in ('kicked', 'left')
$$;

-- 이전 앱: 가장 최근 참가 1건
create or replace function my_challenge_summary() returns jsonb
  language sql stable security definer set search_path = public as $$
  select challenge_session((select p.challenge_id from participants p
    where p.user_id = auth.uid() and p.status not in ('kicked', 'left') order by p.joined_at desc limit 1))
$$;

-- 내 챌린지 목록(진행 단계 + 결과 공개): 홈 카드용
create or replace function my_challenges() returns jsonb
  language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'challenge', jsonb_build_object('id', c.id, 'name', c.name, 'kind', c.kind, 'status', c.status, 'start_date', c.start_date,
        'end_date', c.end_date, 'capacity', c.capacity, 'join_open', c.join_open),
      'participant', jsonb_build_object('id', p.id, 'status', p.status, 'check_start', p.check_start, 'joined_at', p.joined_at,
        'rank_eligible', p.rank_eligible, 'bmr_locked', p.bmr_locked),
      'stats', participant_rank_stats(p.id, kst_date() - 1)) order by p.joined_at desc), '[]')
  from participants p join challenges c on c.id = p.challenge_id
  where p.user_id = auth.uid() and p.status in ('active', 'record_mode', 'excluded')
    and c.status in ('recruiting', 'checking', 'running', 'closing', 'published')
$$;

-- 초대코드 조회(05 API #2): 종류·참가 마감·참가 가능 여부 추가
create or replace function get_invite(p_code text) returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object('challenge_id', c.id, 'name', c.name, 'kind', c.kind, 'status', c.status, 'start_date', c.start_date,
    'end_date', c.end_date, 'capacity', c.capacity, 'join_open', c.join_open, 'joinable', c.join_open and join_feasible(c, kst_date()),
    'joined', (select count(*) from participants p where p.challenge_id = c.id and p.status not in ('kicked', 'left')),
    'days', c.end_date - c.start_date + 1)
  from challenges c where c.invite_code = upper(p_code) and c.status in ('recruiting', 'checking', 'running')
$$;

revoke execute on function leave_challenge(uuid), open_challenges(), challenge_session(uuid), my_challenges() from public, anon;
grant execute on function leave_challenge(uuid), open_challenges(), challenge_session(uuid), my_challenges() to authenticated, service_role;
