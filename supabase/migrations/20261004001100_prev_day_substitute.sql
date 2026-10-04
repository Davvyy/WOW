-- 빈 끼니 칸 대체값 = max(M_p, 전날 같은 칸 등록 kcal)(docs/02 D61).
-- 평소 많이 먹는 끼니를 비워 두면 M_p 보다 실제에 가깝게 잡고, 전날을 일부러 적게 올려 낮추는 것은 max 로 막는다.
-- 전날 칸 kcal = 그 참가자의 전날 그 칸 확정 기록(confirmed·auto·corrected, counted) 합. 전날의 대체값은 쓰지 않는다(연쇄 없음).
-- 간식 칸은 대체값이 없어 그대로. 점검 시작일 전 날은 전날로 보지 않는다(M_p).
-- 대체값이 들어가는 곳: 빈 칸 · 분석 중 칸(captured/failed) · 한도 초과 건너뜀. 초안 잠정값 max(M_p, 1.3×AI)·하한 F_p 는 그대로.

-- ---------------------------------------------------------------- 섭취
-- 원본(20261001000200_engine.sql)에서 바꾼 것: 끝 인자 p_prev_slots({"breakfast": 420, "lunch": 651}).
-- 칸마다 대체값을 greatest(M_p, p_prev_slots[칸]) 으로 쓰고, p_prev_slots 를 주면 결과에 substitute_values({칸: 쓴 값})를 더한다.
-- p_prev_slots 가 없으면(null) 결과는 예전과 같다(골든 테스트).
-- 인자를 더하면 오버로드가 생겨 이름 호출이 모호해지므로 옛 4인자 함수를 지우고 새로 만든다.
drop function intake_kcal(int, jsonb, int, challenge_rules);
create function intake_kcal(p_bmr int, p_meals jsonb, p_skips_used_this_week int default 0, p_rules challenge_rules default null,
  p_prev_slots jsonb default null)
  returns jsonb language plpgsql immutable as $$
declare
  r challenge_rules := coalesce(p_rules, default_rules());
  v_m numeric := m_p(p_bmr, r);
  v_slot text;
  m jsonb;
  v_i numeric := 0;
  v_i_confirmed numeric := 0;
  v_i_snack numeric := 0;
  v_main int := 0;
  v_snacks int := 0;
  v_skips_today int := 0;
  v_skip_over boolean := false;
  v_sub text[] := '{}';
  v_pending text[] := '{}';
  v_drafts jsonb := '[]';
  v_draft_kcal numeric := 0;
  v_satisfied boolean;
  v_has_skip boolean;
  v_has_pending boolean;
  v_kcal numeric;
  v_status text;
  v_sv numeric;
  v_sub_values jsonb := '{}';
  v_out jsonb;
begin
  foreach v_slot in array array['breakfast', 'lunch', 'dinner']
  loop
    v_satisfied := false; v_has_skip := false; v_has_pending := false;
    for m in select * from jsonb_array_elements(coalesce(p_meals, '[]')) e where e ->> 'slot' = v_slot
    loop
      v_status := m ->> 'status';
      if v_status in ('confirmed', 'auto', 'corrected') then
        v_kcal := coalesce((m ->> 'kcal')::numeric, 0);
        v_i := v_i + v_kcal;
        if v_kcal >= r.snack_kcal then
          v_main := v_main + 1; v_satisfied := true; v_i_confirmed := v_i_confirmed + v_kcal;
        else
          v_snacks := v_snacks + 1; v_i_snack := v_i_snack + v_kcal;
        end if;
      elsif v_status = 'draft' then
        v_kcal := greatest(v_m, r.auto_confirm * coalesce((m ->> 'ai_kcal')::numeric, 0));
        v_i := v_i + v_kcal; v_main := v_main + 1; v_satisfied := true;
        v_draft_kcal := v_draft_kcal + v_kcal;
        v_drafts := v_drafts || jsonb_build_object('slot', v_slot, 'value', v_kcal);
      elsif v_status = 'skipped' then
        v_has_skip := true;
      elsif v_status in ('captured', 'failed') then
        v_has_pending := true;
      end if;
    end loop;

    continue when v_satisfied;
    v_sv := greatest(v_m, coalesce((p_prev_slots ->> v_slot)::numeric, 0)); -- 이 칸의 대체값(D61)
    if v_has_skip then
      if v_skips_today < r.skip_per_day and coalesce(p_skips_used_this_week, 0) + v_skips_today < r.skip_per_week then
        v_skips_today := v_skips_today + 1;
        continue;
      end if;
      v_i := v_i + v_sv; v_sub := v_sub || v_slot::text; v_skip_over := true;
      v_sub_values := v_sub_values || jsonb_build_object(v_slot, v_sv);
      continue;
    end if;
    v_i := v_i + v_sv;
    v_sub_values := v_sub_values || jsonb_build_object(v_slot, v_sv);
    if v_has_pending then v_pending := v_pending || v_slot; else v_sub := v_sub || v_slot::text; end if;
  end loop;

  for m in select * from jsonb_array_elements(coalesce(p_meals, '[]')) e
    where e ->> 'slot' = 'snack' and e ->> 'status' in ('confirmed', 'auto', 'corrected')
  loop
    v_kcal := coalesce((m ->> 'kcal')::numeric, 0);
    v_i := v_i + v_kcal; v_i_snack := v_i_snack + v_kcal; v_snacks := v_snacks + 1;
  end loop;

  v_out := jsonb_build_object(
    'i_d', r1(v_i),
    'm_p', v_m,
    'i_confirmed', v_i_confirmed,
    'i_snack', v_i_snack,
    'main_meal_count', v_main,
    'snack_count', v_snacks,
    'substitute_slots', to_jsonb(v_sub),
    'pending_slots', to_jsonb(v_pending),
    'draft_slots', v_drafts,
    'draft_kcal', v_draft_kcal,
    'skips_today', v_skips_today,
    'skip_over', v_skip_over);
  -- 칸마다 쓴 대체값(빈 칸·분석 중 칸·한도 초과 건너뜀). 전날 값을 받은 계산에서만 붙인다.
  if p_prev_slots is not null then
    v_out := v_out || jsonb_build_object('substitute_values', v_sub_values);
  end if;
  return v_out;
end $$;

revoke execute on function intake_kcal(int, jsonb, int, challenge_rules, jsonb) from public, anon;
grant execute on function intake_kcal(int, jsonb, int, challenge_rules, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------- 시뮬레이터 (05 API #16)
-- 원본(20261001000200_engine.sql)에서 바꾼 것: 입력에 prev_slots 가 있으면 intake_kcal 에 넘긴다. 없으면 예전과 같다.
create or replace function score_simulate_from_inputs(p jsonb) returns jsonb
  language plpgsql stable as $$
declare
  r challenge_rules;
  v_bmr int;
  v_bmr_raw numeric;
  v_weight numeric;
  v_challenge uuid := nullif(p ->> 'challenge_id', '')::uuid;
  v_part participants;
  a jsonb;
  i jsonb;
  s jsonb;
begin
  if p ? 'participant_id' then
    select * into v_part from participants where id = (p ->> 'participant_id')::uuid; -- RLS: 본인·운영자만 보임
    if not found then raise exception 'participant not found' using errcode = 'P0002'; end if;
    v_bmr := v_part.bmr_locked; v_weight := v_part.weight_locked; v_challenge := v_part.challenge_id;
  elsif p ? 'sex' then
    v_weight := (p ->> 'weight_kg')::numeric;
    v_bmr_raw := bmr_raw((p ->> 'sex')::sex_type, v_weight, (p ->> 'height_cm')::numeric, (p ->> 'age')::int);
    v_bmr := round10(v_bmr_raw);
  else
    v_bmr := (p ->> 'bmr')::int; v_weight := (p ->> 'weight_kg')::numeric;
  end if;
  if v_bmr is null or v_weight is null then
    raise exception 'bmr/weight required' using errcode = '22023';
  end if;

  r := case when v_challenge is null then default_rules() else engine_rules(v_challenge) end;
  a := activity_kcal(v_weight, coalesce((p ->> 'steps_total')::int, 0), p -> 'sessions', coalesce((p ->> 'floors')::int, 0), r);
  i := intake_kcal(v_bmr, p -> 'meals', coalesce((p ->> 'skips_used_this_week')::int, 0), r, p -> 'prev_slots');
  s := score_simulate(v_bmr, (a ->> 'a_d')::numeric, (i ->> 'i_d')::numeric, (i ->> 'main_meal_count')::int, r);

  return jsonb_build_object(
    'bmr', v_bmr,
    'bmr_raw', v_bmr_raw,
    'weight_kg', v_weight,
    'm_p', i -> 'm_p',
    'f_p', s -> 'f_p',
    'activity', a,
    'intake', i,
    'd_d', s -> 'd_d',
    's_d', s -> 's_d',
    'ratio', s -> 'ratio',
    'floor_applied', s -> 'floor_applied',
    'e', r1(v_bmr + (a ->> 'a_d')::numeric));
end $$;

-- ---------------------------------------------------------------- 일 점수 계산
-- 원본(20261004000200_snack_choice.sql)에서 바꾼 것: 전날 칸별 등록 kcal(v_prev)을 만들어 intake_kcal 에 넘기고 inputs 에 남긴다.
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
  v_prev jsonb;
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
  -- 전날 칸별 등록 kcal(D61): 확정 기록만, 간식 칸 제외. 점검 시작일 전 날은 없음(M_p).
  select coalesce(jsonb_object_agg(z.slot, z.kcal), '{}') into v_prev from (
    select m.slot::text as slot, sum(coalesce(m.confirmed_kcal, 0)) as kcal
    from meals m
    where m.participant_id = p_participant and m.local_date = p_date - 1 and m.counted
      and m.status in ('confirmed', 'auto', 'corrected') and m.slot <> 'snack'
      and p_date - 1 >= p.check_start
    group by m.slot) z;
  i := intake_kcal(p.bmr_locked, v_meals, v_skips, r, v_prev);
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
        'sessions', v_sessions, 'meals', v_meals, 'skips_used_this_week', v_skips, 'platform_active_kcal', da.platform_active_kcal,
        'prev_slots', v_prev)),
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

-- ---------------------------------------------------------------- 다시 계산
-- 원본(20261001000300_batch.sql)에서 바꾼 것: 다음 날 대체값이 이 날 기록에 기대므로, 다음 날 행이 있고 확정 전이면 그 날도 다시 계산한다.
-- 다음 날은 compute_daily_score 로 직접 계산해 recompute_day 를 다시 부르지 않는다(하루만, 연쇄 재귀 없음).
-- 확정된 다음 날은 바꾸지 않는다(확정 뒤에는 정정 경로로만, 04 §5.4).
create or replace function recompute_day(p_participant uuid, p_date date, p_reason revision_reason default 'user_edit',
  p_review_id uuid default null, p_actor uuid default null) returns daily_scores
  language plpgsql as $$
declare
  v_final boolean;
  v_next_final boolean;
  res daily_scores;
begin
  select is_final into v_final from daily_scores where participant_id = p_participant and local_date = p_date;
  res := compute_daily_score(p_participant, p_date, case when v_final then 'revise' else 'provisional' end, p_reason, p_review_id, p_actor);
  select is_final into v_next_final from daily_scores where participant_id = p_participant and local_date = p_date + 1;
  if found and not v_next_final then
    perform compute_daily_score(p_participant, p_date + 1, 'provisional');
  end if;
  return res;
end $$;

-- 확정 전 날짜는 새 규칙으로 한 번 다시 계산한다(확정된 날짜는 그대로)
do $$
declare d record;
begin
  for d in select participant_id, local_date from daily_scores where not is_final order by local_date
  loop
    perform compute_daily_score(d.participant_id, d.local_date, 'provisional');
  end loop;
end $$;
