-- 겹치는 챌린지 경계 보완(docs/02 D47·D52). 출시 전 마지막 점검에서 나온 것들.

-- F1. 000600 이 meals(photo_id) 단독 유니크 인덱스를 (participant_id, photo_id) 로 바꿔 photo_id 만으로 찾는 인덱스가 없어졌다
create index meals_photo_idx on meals (photo_id) where photo_id is not null;

-- ---------------------------------------------------------------- 직접 입력 끼니 (API #10)
-- F2. 원본(20261003000600_meal_fanout.sql)에서 대표 참가만 바꿨다: 가장 최근 참가 대신, 참가 중인 챌린지 중
-- 그 날짜를 품는(기간 안·점검 시작 이후) 가장 최근 참가. 달이 바뀌는 날 지난달 날짜를 입력해도 지난달 챌린지에 들어간다.
create or replace function create_manual_meal(p_user uuid, p_slot meal_slot, p_items jsonb, p_local_date date default null,
  p_now timestamptz default now()) returns jsonb
  language plpgsql as $$
declare p participants; ch challenges; v_date date := coalesce(p_local_date, kst_date(p_now)); v_meal uuid; r jsonb; v_n int;
  q participants; qch challenges;
begin
  select x.* into p from active_participations(p_user) x join challenges c on c.id = x.challenge_id
  where v_date between c.start_date and c.end_date and x.check_start <= v_date
  order by x.joined_at desc limit 1;
  if p.id is null then
    if not exists (select 1 from active_participations(p_user)) then
      raise exception '진행 중인 챌린지가 없어요' using errcode = 'PT403';
    end if;
    raise exception '오늘부터 이틀 전까지만 입력할 수 있어요' using errcode = 'PT422';
  end if;
  select * into ch from challenges where id = p.challenge_id;
  if v_date > kst_date(p_now) or v_date < kst_date(p_now) - 2 or v_date < ch.start_date or v_date > ch.end_date then
    raise exception '오늘부터 이틀 전까지만 입력할 수 있어요' using errcode = 'PT422';
  end if;
  if exists (select 1 from daily_scores where participant_id = p.id and local_date = v_date and is_final) then
    raise exception '확정된 날짜예요' using errcode = 'PT422';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'items 가 비었어요' using errcode = 'PT422'; end if;
  insert into meals (participant_id, challenge_id, local_date, slot, status, engine, captured_at)
  values (p.id, p.challenge_id, v_date, p_slot, 'captured', 'none', p_now) returning id into v_meal;
  -- 기록 공유(D52): 복사본을 먼저 만들고, 대표 확정(confirm_meal)이 복사본까지 확정한다
  for q in select * from active_participations(p_user) where id <> p.id
  loop
    select * into qch from challenges where id = q.challenge_id;
    continue when v_date < qch.start_date or v_date > qch.end_date or v_date < q.check_start
      or exists (select 1 from daily_scores where participant_id = q.id and local_date = v_date and is_final);
    insert into meals (participant_id, challenge_id, local_date, slot, status, engine, captured_at, record_group_id)
    values (q.id, q.challenge_id, v_date, p_slot, 'captured', 'none', p_now, v_meal);
  end loop;
  r := confirm_meal(p_user, v_meal,
    (select jsonb_agg(x || jsonb_build_object('input_type', coalesce(x ->> 'input_type', 'manual'))) from jsonb_array_elements(p_items) x),
    1, p_now);
  select count(*) into v_n from meals m where m.participant_id = p.id and m.local_date = v_date and m.photo_id is null
    and m.status in ('confirmed', 'corrected');
  if v_n >= 3 then
    perform raise_flag(p.id, v_date, 'manual_input_burst', jsonb_build_object('key', v_date::text, 'count', v_n), p_now);
  end if;
  return r || jsonb_build_object('local_date', v_date, 'slot', p_slot, 'manual_count_today', v_n);
end $$;

-- ---------------------------------------------------------------- 사진 끼니 만들기 (API #9)
-- F2. 원본(20261003000600_meal_fanout.sql)에서 두 군데만 바꿨다.
-- (1) 태그 날짜가 사진 주인 참가의 기간·점검 시작 밖이면, 그 날짜를 품는 가장 최근 참가를 대표로 쓴다(사진 행은 그대로).
-- (2) 재요청 확인: 이 사진의 대표 끼니가 본인의 어느 참가에든 있으면 그것을 돌려준다.
create or replace function create_meal(p_user uuid, p_photo uuid, p_queued boolean default false, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  ph photos; p participants; ch challenges; r challenge_rules;
  v_tag_at timestamptz := p_now;
  v_diff interval;
  v_late boolean := false;
  v_counted boolean := true;
  v_date date; v_slot meal_slot;
  v_engine ai_engine := 'none';
  v_meal uuid;
  v_dup boolean;
  q participants; qch challenges; v_copy uuid; v_qcounted boolean;
  v_alt participants;
begin
  select * into ph from photos where id = p_photo;
  if not found then raise exception 'photo not found' using errcode = 'PT404'; end if;
  select * into p from participants where id = ph.participant_id;
  if p.user_id is distinct from p_user then raise exception 'not your photo' using errcode = 'PT403'; end if;
  if ph.verified_at is null then raise exception '사진 업로드 확인 전이에요' using errcode = 'PT422'; end if;
  if exists (select 1 from meals m join participants x on x.id = m.participant_id
             where m.photo_id = p_photo and m.record_group_id = m.id and x.user_id = p_user) then
    return (select jsonb_build_object('meal_id', m.id, 'status', m.status, 'local_date', m.local_date, 'slot', m.slot, 'replayed', true)
      from meals m join participants x on x.id = m.participant_id
      where m.photo_id = p_photo and m.record_group_id = m.id and x.user_id = p_user
      order by m.captured_at limit 1);
  end if;
  select * into ch from challenges where id = p.challenge_id;
  r := engine_rules(ch.id);

  if p_queued and ph.client_captured_at is not null and ph.client_captured_at < p_now then
    v_diff := p_now - ph.client_captured_at;
    if v_diff > interval '30 minutes' then
      v_late := true;
      if exists (select 1 from daily_scores where participant_id = p.id and local_date = kst_date(ph.client_captured_at) and is_final) then
        v_tag_at := ph.client_captured_at; v_counted := false;
      elsif v_diff <= r.late_upload_window then
        v_tag_at := ph.client_captured_at;
      end if;
    end if;
  end if;
  v_date := kst_date(v_tag_at);
  -- 겹치는 챌린지 경계(F2): 사진 주인 참가가 이 날짜를 품지 않으면, 품는 참가 중 가장 최근 것을 대표로
  if v_date < ch.start_date or v_date > ch.end_date or v_date < p.check_start then
    select x.* into v_alt from active_participations(p_user) x join challenges c on c.id = x.challenge_id
    where v_date between c.start_date and c.end_date and x.check_start <= v_date
    order by x.joined_at desc limit 1;
    if v_alt.id is not null then
      p := v_alt;
      select * into ch from challenges where id = p.challenge_id;
      r := engine_rules(ch.id);
    end if;
  end if;
  v_slot := slot_for(v_tag_at, r);
  if v_counted and (v_date < ch.start_date or v_date > ch.end_date) then
    raise exception '챌린지 기간 밖의 사진이에요' using errcode = 'PT422';
  end if;
  if v_counted and exists (select 1 from daily_scores where participant_id = p.id and local_date = v_date and is_final) then
    v_counted := false; -- 확정된 날짜로 태그되는 경우(서버 시각 기준)도 미인정
  end if;
  if exists (select 1 from consents where user_id = p_user and type = 'overseas_ai' and revoked_at is null) then
    v_engine := 'gemini';
  end if;

  insert into meals (participant_id, challenge_id, local_date, slot, status, photo_id, engine, late_upload, counted, captured_at)
  values (p.id, p.challenge_id, v_date, v_slot, 'captured', p_photo, v_engine, v_late, v_counted, p_now)
  returning id into v_meal;

  if v_late then
    perform raise_flag(p.id, v_date, 'late_upload', jsonb_build_object('key', v_meal::text, 'meal_id', v_meal,
      'client_captured_at', ph.client_captured_at, 'server_received_at', p_now, 'counted', v_counted), p_now);
  end if;
  -- 사진 SHA-256 중복(본인·타인, 서버 해시 기준) → dup_photo 검토 중
  select exists (select 1 from photos o where o.sha256_server = ph.sha256_server and o.id <> ph.id) into v_dup;
  if v_dup then
    perform raise_flag(p.id, v_date, 'dup_photo', jsonb_build_object('key', v_meal::text, 'meal_id', v_meal, 'photo_id', p_photo), p_now);
  end if;
  if v_counted then perform recompute_day(p.id, v_date); end if;

  -- 기록 공유(D52): 참가 중인 다른 챌린지에 같은 사진의 끼니를 복사한다. 플래그는 각 챌린지 운영자가 보도록 복사본에도.
  for q in select * from active_participations(p_user) where id <> p.id
  loop
    select * into qch from challenges where id = q.challenge_id;
    continue when v_date < qch.start_date or v_date > qch.end_date or v_date < q.check_start;
    v_qcounted := v_counted and not exists (select 1 from daily_scores where participant_id = q.id and local_date = v_date and is_final);
    insert into meals (participant_id, challenge_id, local_date, slot, status, photo_id, engine, late_upload, counted, captured_at, record_group_id)
    values (q.id, q.challenge_id, v_date, v_slot, 'captured', p_photo, v_engine, v_late, v_qcounted, p_now, v_meal)
    returning id into v_copy;
    if v_late then
      perform raise_flag(q.id, v_date, 'late_upload', jsonb_build_object('key', v_copy::text, 'meal_id', v_copy,
        'client_captured_at', ph.client_captured_at, 'server_received_at', p_now, 'counted', v_qcounted), p_now);
    end if;
    if v_dup then
      perform raise_flag(q.id, v_date, 'dup_photo', jsonb_build_object('key', v_copy::text, 'meal_id', v_copy, 'photo_id', p_photo), p_now);
    end if;
    if v_qcounted then perform recompute_day(q.id, v_date); end if;
  end loop;

  return jsonb_build_object('meal_id', v_meal, 'status', 'captured', 'local_date', v_date, 'slot', v_slot, 'engine', v_engine,
    'late_upload', v_late, 'counted', v_counted, 'dup_photo', v_dup, 'analyze', v_engine <> 'none' and v_counted);
end $$;

-- ---------------------------------------------------------------- 참가(05 API #3)
-- 원본(20261003000400_join_leave.sql)에서 바꾼 것:
-- F3. 끝나고 공개 전(closing)인 챌린지는 동시 3개 제한에 세지 않는다(월간은 운영자가 공개할 때까지 closing 에 머문다).
-- F5. 이미 참가 중이면 다른 확인보다 먼저 그 참가를 돌려주고, 3개 제한을 세기 전에 사용자별 잠금을 잡는다.
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
  -- 이미 이 챌린지에 참가 중이면 다시 참가(닉네임 갱신): 마감·남은 기간·동의·정원·3개 제한보다 먼저(재시도 멱등)
  select * into v_part from participants where challenge_id = ch.id and user_id = v_uid and status in ('active', 'record_mode', 'excluded');
  if found then
    update participants set nickname = coalesce(p ->> 'nickname', nickname) where id = v_part.id returning * into v_part;
    return jsonb_build_object('participant_id', v_part.id, 'challenge_id', ch.id, 'kind', ch.kind, 'check_start', v_part.check_start,
      'bmr', v_part.bmr_locked, 'm_p', m_p(v_part.bmr_locked, engine_rules(ch.id)), 'f_p', f_p(v_part.bmr_locked, engine_rules(ch.id)),
      'record_mode', v_part.status = 'record_mode');
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
  perform pg_advisory_xact_lock(hashtext(v_uid::text)); -- 같은 사용자의 동시 참가 요청이 함께 3개 제한을 넘지 않게
  if not exists (select 1 from participants where challenge_id = ch.id and user_id = v_uid and status in ('active', 'record_mode', 'excluded')) then
    select count(*) into v_active from participants q join challenges c on c.id = q.challenge_id
      where q.user_id = v_uid and q.status in ('active', 'record_mode', 'excluded')
        and c.status in ('recruiting', 'checking', 'running');
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

-- ---------------------------------------------------------------- 월간 자동 챌린지(D46·D51)
-- F3. 원본(20261003000500_monthly_challenge.sql)에서 자동 이어하기의 동시 3개 제한에 closing 을 세지 않게만 바꿨다.
create or replace function ensure_monthly_challenge(p_now timestamptz default now()) returns uuid
  language plpgsql as $$
declare
  v_start date := date_trunc('month', kst_date(p_now))::date;
  v_end date := (date_trunc('month', kst_date(p_now)) + interval '1 month - 1 day')::date;
  v_op uuid := (select (value #>> '{}')::uuid from app_settings where key = 'monthly_operator_id');
  v_id uuid; v_prev uuid; x record; v_age int; v_n int;
begin
  select id into v_id from challenges where kind = 'monthly' and start_date = v_start;
  if v_id is not null then return v_id; end if;
  if v_op is null then
    raise notice 'monthly_operator_id not set — monthly challenge skipped';
    return null;
  end if;
  insert into challenges (name, kind, status, start_date, end_date, capacity, operator_id)
  values (format('%s월 챌린지', extract(month from v_start)::int), 'monthly', 'running', v_start, v_end, null, v_op)
  returning id into v_id;
  insert into challenge_rules (challenge_id, locked_at) values (v_id, p_now);
  perform write_audit(v_id, null, 'system', 'monthly_create', jsonb_build_object('start_date', v_start, 'end_date', v_end));

  select id into v_prev from challenges where kind = 'monthly' and start_date = (v_start - interval '1 month')::date;
  if v_prev is null then return v_id; end if;
  for x in
    select pt.user_id, pt.nickname, pr.sex, pr.birth_year, pr.height_cm, pr.weight_kg, pr.record_mode
    from participants pt
    join profiles pr on pr.user_id = pt.user_id
    join users u on u.id = pt.user_id
    where pt.challenge_id = v_prev and pt.status in ('active', 'record_mode') and pr.auto_continue and u.status = 'active'
  loop
    select count(*) into v_n from participants q join challenges c on c.id = q.challenge_id
      where q.user_id = x.user_id and q.status in ('active', 'record_mode', 'excluded')
        and c.status in ('recruiting', 'checking', 'running') and c.id not in (v_id, v_prev);
    continue when v_n >= 3;
    v_age := extract(year from v_start)::int - x.birth_year;
    insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked,
      status, rank_eligible, joined_at, check_start)
    values (v_id, x.user_id, x.nickname, x.sex, x.birth_year, v_age, x.height_cm, x.weight_kg,
      bmr_kcal(x.sex, x.weight_kg, x.height_cm, v_age),
      (case when x.record_mode then 'record_mode' else 'active' end)::participant_status, not x.record_mode, p_now, v_start)
    on conflict (challenge_id, user_id) do nothing;
  end loop;
  return v_id;
end $$;

-- ---------------------------------------------------------------- 00:00 KST 생명주기 배치
-- F4. 원본(20261003000500_monthly_challenge.sql)에서 월간 챌린지 생성 오류가 나머지 전환을 막지 않게만 바꿨다.
create or replace function run_lifecycle(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare ch challenges; v_today date := kst_date(p_now); n int := 0; r challenge_rules;
begin
  begin
    perform ensure_monthly_challenge(p_now);
  exception when others then
    raise warning 'monthly challenge skipped: %', sqlerrm;
  end;
  for ch in select * from challenges where status in ('recruiting', 'checking', 'published')
  loop
    r := engine_rules(ch.id);
    if ch.status = 'recruiting' and v_today >= ch.start_date then
      perform transition_challenge(ch.id, 'checking', null, p_now); n := n + 1;
    elsif ch.status = 'checking' and v_today >= ch.start_date + r.check_days then
      perform transition_challenge(ch.id, 'running', null, p_now); n := n + 1;
    elsif ch.status = 'published' and p_now >= ch.published_at + interval '7 days' then
      perform transition_challenge(ch.id, 'archived', null, p_now); n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- 참가자 상태 감사 로그
-- F6. 원본(20261001000400_rls.sql)에서 actor_role 만 바꿨다: 본인 변경(나가기 등)은 participant, 로그인 없음은 system, 그 외 operator.
create or replace function participants_audit() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if (new.status, new.block_rejoin) is distinct from (old.status, old.block_rejoin) then
    insert into audit_logs (challenge_id, actor_id, actor_role, action, target, before, after)
    values (old.challenge_id, auth.uid(),
      case when auth.uid() is null then 'system' when auth.uid() = old.user_id then 'participant' else 'operator' end,
      'participant_status',
      jsonb_build_object('participant_id', old.id),
      jsonb_build_object('status', old.status, 'block_rejoin', old.block_rejoin),
      jsonb_build_object('status', new.status, 'block_rejoin', new.block_rejoin));
  end if;
  return null;
end $$;
