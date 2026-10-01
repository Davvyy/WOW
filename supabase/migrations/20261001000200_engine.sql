-- 점수 엔진 (docs/04 §2~§5, docs/05 §7, prototype/data.js ENGINE)
-- "SQL 함수 1개 = /simulate"(02 §8): 화면(P5·P11·OP1)과 배치(매시 잠정·09:00 확정)가 모두 아래 함수를 호출한다.
--   activity_kcal            걸음·세션·층수 → A_d
--   intake_kcal              끼니 목록 → I_d (대체값·간식·초안·건너뜀)
--   score_simulate           BMR·A_d·I_d·끼니 수 → D_d·S_d
--   score_simulate_from_inputs  위 셋을 잇는 RPC 래퍼(05 API #16)
-- 반올림(앱 Dart 엔진·프로토타입 공통): r1(x) = floor(x*10 + 0.5)/10, round10(x) = floor(x/10 + 0.5)*10.
-- 골든 테스트: supabase/tests/golden_cases.json (run.sh)

create or replace function r1(x numeric) returns numeric
  language sql immutable parallel safe as $$ select trunc(floor(x * 10 + 0.5) / 10, 1) $$;

create or replace function round10(x numeric) returns int
  language sql immutable parallel safe as $$ select (floor(x / 10 + 0.5) * 10)::int $$;

-- 04 §2 Mifflin-St Jeor, 10 kcal 단위 half-up
create or replace function bmr_raw(p_sex sex_type, p_weight numeric, p_height numeric, p_age int) returns numeric
  language sql immutable parallel safe as $$
  select 10 * p_weight + 6.25 * p_height - 5 * p_age + case when p_sex = 'M' then 5 else -161 end
$$;

create or replace function bmr_kcal(p_sex sex_type, p_weight numeric, p_height numeric, p_age int) returns int
  language sql immutable parallel safe as $$ select round10(bmr_raw(p_sex, p_weight, p_height, p_age)) $$;

-- 챌린지 규칙 행이 없을 때의 기본값(04 §5.2). 컬럼 기본값과 같아야 한다(golden 테스트가 검사).
create or replace function default_rules() returns challenge_rules
  language sql immutable as $$
  select jsonb_populate_record(null::challenge_rules, jsonb_build_object(
    't', 500, 'c', 1000, 's_max', 150, 'm_min', 700, 'm_ratio', 0.45, 'f_min', 1200, 'f_ratio', 0.8,
    'auto_confirm', 1.3, 'nudge_min_m', 1500, 'nudge_min_f', 1200, 'snack_kcal', 150,
    'steps_cap', 30000, 'floors_cap', 50, 'step_met', 3.8, 'stair_met', 6.8, 'sec_per_floor', 17.5,
    'broth_factor', 0.6, 'skip_per_day', 1, 'skip_per_week', 3, 'check_days', 3,
    'steps_spike_abs', 25000, 'steps_spike_ratio', 2.5,
    'breakfast_start', '04:00', 'breakfast_end', '10:30', 'lunch_end', '15:00', 'dinner_end', '22:00',
    'late_upload_window', '12 hours', 'edit_window', '48 hours', 'appeal_window', '72 hours', 'finalize_time', '09:00',
    'origin_whitelist', jsonb_build_array('com.apple.health', 'com.sec.android.app.shealth', 'android',
      'com.google.android.apps.healthdata', 'com.garmin.android.apps.connectmobile', 'com.fitbit.FitbitMobile',
      'com.huami.watch.hmwatchmanager', 'com.xiaomi.wearable')))
$$;

create or replace function engine_rules(p_challenge_id uuid) returns challenge_rules
  language sql stable as $$
  select coalesce((select r from challenge_rules r where r.challenge_id = p_challenge_id), default_rules())
$$;

create or replace function m_p(p_bmr int, p_rules challenge_rules default null) returns numeric
  language sql immutable as $$
  select greatest((coalesce(p_rules, default_rules())).m_min, (coalesce(p_rules, default_rules())).m_ratio * p_bmr)
$$;

create or replace function f_p(p_bmr int, p_rules challenge_rules default null) returns numeric
  language sql immutable as $$
  select greatest((coalesce(p_rules, default_rules())).f_min, (coalesce(p_rules, default_rules())).f_ratio * p_bmr)
$$;

-- 04 §3.3 달리기 속도 tier, 반개구간 [하한, 상한)
create or replace function run_met(p_kmh numeric) returns numeric
  language sql immutable parallel safe as $$
  select case when p_kmh >= 12.9 then 12.0 when p_kmh >= 9.7 then 9.3 when p_kmh >= 8.0 then 8.5 else 7.5 end
$$;

-- 세션 1건의 MET. 걷기 세션은 null(걸음 경로만, T04). 거리 없는 달리기는 7.5.
create or replace function session_met(p_type text, p_minutes numeric, p_distance_m numeric, p_rules challenge_rules default null)
  returns numeric language sql immutable as $$
  select case p_type
    when 'walking' then null
    when 'stair' then (coalesce(p_rules, default_rules())).stair_met
    when 'running' then case
      when coalesce(p_distance_m, 0) <= 0 or coalesce(p_minutes, 0) <= 0 then 7.5
      else run_met(p_distance_m * 60 / (p_minutes * 1000)) end
    else null end
$$;

-- 05 §7 activity_kcal: 걸음 3.8 고정·세션 tier·층수·상한을 한 곳에.
-- p_sessions: [{type, minutes, distance_m, steps_in_range, met?, is_counted?, recording_method?}]
create or replace function activity_kcal(
  p_weight numeric, p_steps_total int, p_sessions jsonb, p_floors int, p_rules challenge_rules default null
) returns jsonb language plpgsql immutable as $$
declare
  r challenge_rules := coalesce(p_rules, default_rules());
  s jsonb;
  v_met numeric;
  v_minutes numeric;
  v_session_steps int := 0;
  v_sess numeric := 0;
  v_steps_out int;
  v_steps numeric;
  v_floors numeric := 0;
  v_raw numeric;
  v_mets jsonb := '[]';
begin
  for s in select * from jsonb_array_elements(coalesce(p_sessions, '[]'))
  loop
    if coalesce((s ->> 'is_counted')::boolean, true) = false then continue; end if;
    if upper(coalesce(s ->> 'recording_method', '')) = 'MANUAL_ENTRY' then continue; end if;
    v_minutes := (s ->> 'minutes')::numeric;
    v_met := coalesce((s ->> 'met')::numeric, session_met(s ->> 'type', v_minutes, (s ->> 'distance_m')::numeric, r));
    if v_met is null then continue; end if;
    v_session_steps := v_session_steps + coalesce((s ->> 'steps_in_range')::int, 0);
    v_sess := v_sess + (v_met - 1) * p_weight * (v_minutes / 60);
    v_mets := v_mets || to_jsonb(v_met);
  end loop;

  v_steps_out := least(greatest(0, coalesce(p_steps_total, 0) - v_session_steps), r.steps_cap);
  v_steps := v_steps_out * (r.step_met - 1) * p_weight / 6000;
  if coalesce(p_floors, 0) > 0 then
    v_floors := least(p_floors, r.floors_cap) * (r.stair_met - 1) * p_weight * r.sec_per_floor / 3600;
  end if;
  v_raw := v_steps + v_sess + v_floors;

  return jsonb_build_object(
    'steps_out', v_steps_out,
    'steps_net_kcal', r1(v_steps),
    'sessions_net_kcal', r1(v_sess),
    'floors_kcal', r1(v_floors),
    'a_raw', r1(v_raw),
    'a_d', r1(least(v_raw, r.c)),
    'a_capped', v_raw > r.c,
    'session_mets', v_mets);
end $$;

-- 04 §4.3 I_d = Σ 확정 끼니(≥150) + Σ 간식(<150) + 빈 주식 슬롯 × M_p
-- p_meals: [{slot, status, kcal, ai_kcal}] — status 는 meal_status 값 또는 'empty'
--  · confirmed/auto/corrected: kcal 합산, ≥150 이면 끼니(슬롯 충족), <150 이면 간식(슬롯 미충족)
--  · draft: 잠정으로 max(M_p, 1.3×AI) 산입, 슬롯 충족(09:00 자동 확정값과 동일)
--  · captured/failed: 빈 슬롯처럼 M_p (pending)
--  · skipped: 1일 skip_per_day·주 skip_per_week 한도 안이면 0, 초과분 M_p
--  · void/empty/없음: M_p
-- 간식 슬롯(snack)의 확정 kcal 은 합산만 한다(끼니 수에 넣지 않음, 프로토타입과 동일).
create or replace function intake_kcal(p_bmr int, p_meals jsonb, p_skips_used_this_week int default 0, p_rules challenge_rules default null)
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
    if v_has_skip then
      if v_skips_today < r.skip_per_day and coalesce(p_skips_used_this_week, 0) + v_skips_today < r.skip_per_week then
        v_skips_today := v_skips_today + 1;
        continue;
      end if;
      v_i := v_i + v_m; v_sub := v_sub || v_slot; v_skip_over := true;
      continue;
    end if;
    v_i := v_i + v_m;
    if v_has_pending then v_pending := v_pending || v_slot; else v_sub := v_sub || v_slot; end if;
  end loop;

  for m in select * from jsonb_array_elements(coalesce(p_meals, '[]')) e
    where e ->> 'slot' = 'snack' and e ->> 'status' in ('confirmed', 'auto', 'corrected')
  loop
    v_kcal := coalesce((m ->> 'kcal')::numeric, 0);
    v_i := v_i + v_kcal; v_i_snack := v_i_snack + v_kcal; v_snacks := v_snacks + 1;
  end loop;

  return jsonb_build_object(
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
end $$;

-- 04 §5.1 D_d = (BMR + min(A_d, C)) − max(I_d, F_p),  S_d = 100 × clamp(D_d/T, 0, 1.5), 끼니 0개 → 0
create or replace function score_simulate(p_bmr int, p_a_d numeric, p_i_d numeric, p_main_meal_count int, p_rules challenge_rules default null)
  returns jsonb language plpgsql immutable as $$
declare
  r challenge_rules := coalesce(p_rules, default_rules());
  v_f numeric := f_p(p_bmr, r);
  v_d numeric;
  v_ratio numeric;
  v_s numeric;
begin
  v_d := p_bmr + least(p_a_d, r.c) - greatest(p_i_d, v_f);
  v_ratio := least(greatest(v_d / r.t, 0), r.s_max / 100);
  v_s := case when coalesce(p_main_meal_count, 0) = 0 then 0 else 100 * v_ratio end;
  return jsonb_build_object(
    'f_p', v_f,
    'floor_applied', p_i_d < v_f,
    'd_d', r1(v_d),
    's_d', r1(v_s),
    'ratio', v_ratio,
    'zero_meals', coalesce(p_main_meal_count, 0) = 0);
end $$;

-- 05 API #16. 입력: {sex, weight_kg, height_cm, age} 또는 {bmr, weight_kg} 또는 {participant_id},
--   steps_total, sessions[], floors, meals[], skips_used_this_week, challenge_id?
-- P11(앱)·OP1(콘솔)·골든 테스트가 이 함수만 호출한다.
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
  i := intake_kcal(v_bmr, p -> 'meals', coalesce((p ->> 'skips_used_this_week')::int, 0), r);
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

-- 04 §4.2 kcal = 1인분 × 분량 배수 × 개수 × 국물 계수 × 1젓가락 비율
create or replace function meal_item_kcal(p_serving_kcal numeric, p_multiplier numeric, p_count int, p_broth_off boolean,
  p_bite_fraction numeric default 1, p_rules challenge_rules default null) returns numeric
  language sql immutable as $$
  select r1(p_serving_kcal * p_multiplier * p_count
    * case when p_broth_off then (coalesce(p_rules, default_rules())).broth_factor else 1 end
    * coalesce(p_bite_fraction, 1))
$$;
