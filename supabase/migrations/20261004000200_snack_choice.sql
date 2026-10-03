-- 촬영 화면에서 '간식'을 고르면 간식 슬롯으로 저장하고, 미확정 간식 초안은 대체값 하한 없이 자동 확정한다(docs/02 D55).
-- 아침·점심·저녁은 지금처럼 서버 시각으로 태그한다. 간식은 끼니 슬롯을 채우지 않아 이렇게 골라도 점수 이득이 없다.

-- ---------------------------------------------------------------- 일 점수 계산
-- 원본(20261004000100_skip_prejoin_days.sql)에서 09:00 자동 확정만 바꿨다:
-- 간식 슬롯 초안은 auto_confirm × AI 로만 확정한다(간식은 대체값이 없다, 02 §5). 끼니 초안은 그대로 max(M_p, auto_confirm × AI).
create or replace function compute_daily_score(p_participant uuid, p_date date, p_mode text default 'provisional',
  p_reason revision_reason default null, p_review_id uuid default null, p_actor uuid default null)
  returns daily_scores language plpgsql as $$
declare
  p participants;
  ch challenges;
  r challenge_rules;
  da daily_activity;
  prev daily_scores;
  res daily_scores;
  v_sessions jsonb;
  v_session_steps int;
  v_steps_total int;
  v_meals jsonb;
  v_skips int;
  a jsonb; i jsonb; s jsonb;
  v_m numeric;
  v_under_review boolean;
  v_is_final boolean;
begin
  select * into p from participants where id = p_participant;
  if not found then raise exception 'participant % not found', p_participant using errcode = 'P0002'; end if;
  select * into ch from challenges where id = p.challenge_id;
  -- 참가 전 날짜는 계산하지 않는다(중간 참가, D48). 동기화가 최근 3일을 보내도 점수 행을 만들지 않는다.
  if p_date < p.check_start then return null; end if;
  r := engine_rules(p.challenge_id);
  select * into prev from daily_scores where participant_id = p_participant and local_date = p_date;

  if p_mode = 'provisional' and prev.is_final then
    return prev; -- 확정 뒤에는 정정 경로로만 바뀐다(04 §5.4)
  end if;

  v_m := m_p(p.bmr_locked, r);
  if p_mode = 'finalize' then
    -- 04 §4.3 미확정 AI 초안 자동 확정
    -- 간식 초안은 대체값 하한 없이 auto_confirm × AI(D55)
    update meals set status = 'auto',
      confirmed_kcal = case when slot = 'snack' then r.auto_confirm * coalesce(ai_kcal, 0)
                            else greatest(v_m, r.auto_confirm * coalesce(ai_kcal, 0)) end,
      delta_ratio = case when ai_kcal > 0 then
                      case when slot = 'snack' then r.auto_confirm
                           else greatest(v_m, r.auto_confirm * ai_kcal) / ai_kcal end end,
      confirmed_at = now()
    where participant_id = p_participant and local_date = p_date and status = 'draft' and counted;
  end if;

  -- 활동 입력
  select * into da from daily_activity where participant_id = p_participant and local_date = p_date;
  select coalesce(jsonb_agg(jsonb_build_object(
      'type', s.type, 'minutes', extract(epoch from (s.end_at - s.start_at)) / 60,
      'distance_m', s.distance_m, 'steps_in_range', s.steps_in_range)), '[]'),
    coalesce(sum(s.steps_in_range) filter (where s.type <> 'walking'), 0)
  into v_sessions, v_session_steps
  from activity_sessions s
  where s.participant_id = p_participant and s.local_date = p_date and s.is_counted
    and upper(coalesce(s.recording_method, '')) <> 'MANUAL_ENTRY';
  -- 검증 걸음 = 합계 − 수동(iOS) − 판정 제외분. steps_spike 무효 판정은 세션 밖 걸음을 기준선으로 대체.
  v_steps_total := greatest(0, coalesce(da.steps_total, 0) - coalesce(da.steps_manual, 0) - coalesce(da.steps_excluded, 0));
  if da.steps_out_override is not null then
    v_steps_total := da.steps_out_override + v_session_steps;
  end if;
  a := activity_kcal(p.weight_locked, v_steps_total, v_sessions, coalesce(da.floors, 0), r);

  -- 섭취 입력(counted=false 지연 업로드 끼니는 제외)
  select coalesce(jsonb_agg(jsonb_build_object('slot', m.slot, 'status', m.status, 'kcal', m.confirmed_kcal, 'ai_kcal', m.ai_kcal)), '[]')
  into v_meals from meals m where m.participant_id = p_participant and m.local_date = p_date and m.counted;
  v_skips := skips_used_before(p_participant, p_date, r);
  i := intake_kcal(p.bmr_locked, v_meals, v_skips, r);
  s := score_simulate(p.bmr_locked, (a ->> 'a_d')::numeric, (i ->> 'i_d')::numeric, (i ->> 'main_meal_count')::int, r);

  select exists (select 1 from reviews rv where rv.participant_id = p_participant and rv.local_date = p_date
    and rv.status in ('open', 'appealed') and rv.type not in ('session_anomaly', 'manual_input_burst', 'late_upload', 'photo_mismatch', 'objection'))
  into v_under_review;
  v_is_final := coalesce(prev.is_final, false) or p_mode = 'finalize';

  if da.id is not null then
    update daily_activity set steps_in_sessions = v_session_steps,
      steps_net_kcal = (a ->> 'steps_net_kcal')::numeric, sessions_net_kcal = (a ->> 'sessions_net_kcal')::numeric,
      floors_kcal = (a ->> 'floors_kcal')::numeric, a_raw = (a ->> 'a_raw')::numeric, a_capped = (a ->> 'a_d')::numeric
    where id = da.id;
  end if;

  insert into daily_scores as d (participant_id, challenge_id, local_date, bmr, a_d, i_confirmed, i_snack, substitute_slots, m_p,
    i_d, f_p, d_d, s_d, main_meal_count, is_counted, is_final, finalized_at, under_review, breakdown, computed_at)
  values (p_participant, p.challenge_id, p_date, p.bmr_locked, (a ->> 'a_d')::numeric, (i ->> 'i_confirmed')::numeric,
    (i ->> 'i_snack')::numeric, jsonb_array_length(i -> 'substitute_slots') + jsonb_array_length(i -> 'pending_slots'),
    v_m, (i ->> 'i_d')::numeric, (s ->> 'f_p')::numeric, (s ->> 'd_d')::numeric, (s ->> 's_d')::numeric,
    (i ->> 'main_meal_count')::int,
    (p_date - p.check_start) >= r.check_days, -- 개인 점검 기간(D48)
    v_is_final, case when p_mode = 'finalize' then now() else prev.finalized_at end,
    v_under_review,
    jsonb_build_object('activity', a, 'intake', i, 'score', s,
      'inputs', jsonb_build_object('steps_total', da.steps_total, 'steps_manual', da.steps_manual, 'steps_excluded', da.steps_excluded,
        'steps_out_override', da.steps_out_override, 'steps_verified', v_steps_total, 'floors', da.floors,
        'sessions', v_sessions, 'meals', v_meals, 'skips_used_this_week', v_skips, 'platform_active_kcal', da.platform_active_kcal)),
    now())
  on conflict (participant_id, local_date) do update set
    bmr = excluded.bmr, a_d = excluded.a_d, i_confirmed = excluded.i_confirmed, i_snack = excluded.i_snack,
    substitute_slots = excluded.substitute_slots, m_p = excluded.m_p, i_d = excluded.i_d, f_p = excluded.f_p,
    d_d = excluded.d_d, s_d = excluded.s_d, main_meal_count = excluded.main_meal_count, is_counted = excluded.is_counted,
    is_final = excluded.is_final, finalized_at = excluded.finalized_at, under_review = excluded.under_review,
    breakdown = excluded.breakdown, computed_at = excluded.computed_at
  returning * into res;

  if prev.is_final and p_mode = 'revise' and (prev.s_d is distinct from res.s_d or prev.i_d is distinct from res.i_d or prev.a_d is distinct from res.a_d) then
    insert into score_revisions (daily_score_id, participant_id, prev_s_d, new_s_d, prev_breakdown, reason, review_id, actor_id)
    values (res.id, p_participant, prev.s_d, res.s_d, prev.breakdown, coalesce(p_reason, 'user_edit'), p_review_id, p_actor);
  end if;
  return res;
end $$;

-- ---------------------------------------------------------------- 사진 끼니 만들기 (API #9)
-- 원본(20261003001000_fanout_followups.sql)에서 바꾼 것: 끝 인자 p_snack 하나. 참이면 슬롯을 간식으로(복사본도 같은 슬롯).
-- 인자를 더하면 오버로드가 생겨 PostgREST 이름 호출이 모호해지므로 옛 4인자 함수를 지우고 새로 만든다.
drop function create_meal(uuid, uuid, boolean, timestamptz);
create function create_meal(p_user uuid, p_photo uuid, p_queued boolean default false, p_now timestamptz default now(),
  p_snack boolean default false)
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
  if p_snack then v_slot := 'snack'; end if; -- 촬영 화면에서 간식을 고름(D55)
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

revoke execute on function create_meal(uuid, uuid, boolean, timestamptz, boolean) from public, anon, authenticated;
grant execute on function create_meal(uuid, uuid, boolean, timestamptz, boolean) to service_role;
