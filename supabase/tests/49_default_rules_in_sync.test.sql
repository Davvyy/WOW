-- default_rules() 는 새 규칙 행의 컬럼 기본값과 같아야 한다. 한쪽만 고치면 규칙 행이 없을 때의 계산이 실제 챌린지와 달라진다.
-- 예외는 간식 기준 하나: 함수 쪽 150 은 세 엔진이 함께 맞추는 골든 기준값이고, 실제 챌린지는 규칙 행의 0 을 쓴다(D59).
-- 그래서 챌린지 id 를 주면 그 챌린지 규칙으로 계산되는지도 함께 본다.
begin;
do $$
declare op uuid; v_new uuid; a jsonb; b jsonb; k text; sim jsonb;
begin
  select operator_id into op from challenges where invite_code = 'K7Q2MD';
  insert into challenges (name, status, start_date, end_date, capacity, operator_id) values ('기본값 비교', 'draft', '2027-01-04', '2027-01-31', 30, op) returning id into v_new;
  insert into challenge_rules (challenge_id) values (v_new);
  select to_jsonb(r) into a from challenge_rules r where r.challenge_id = v_new;
  b := to_jsonb(default_rules());
  for k in select key from jsonb_object_keys(a) as t(key) where key not in ('challenge_id', 'created_at', 'updated_at', 'locked_at', 'snack_kcal') loop
    perform tests.eq((b -> k)::text, (a -> k)::text, 'default_rules().' || k || ' 가 컬럼 기본값과 같다');
  end loop;
  perform tests.eq((default_rules()).snack_kcal, 150::numeric, '규칙 행이 없을 때 간식 기준은 골든 기준값 150');
  perform tests.eq((a ->> 'snack_kcal')::numeric, 0::numeric, '새 규칙 행의 간식 기준은 0');
  sim := '{"sex": "M", "weight_kg": 70, "height_cm": 175, "age": 30, "steps_total": 0, "sessions": [], "floors": 0, "meals": [{"slot": "breakfast", "status": "confirmed", "kcal": 100}, {"slot": "lunch", "status": "confirmed", "kcal": 100}, {"slot": "dinner", "status": "confirmed", "kcal": 100}]}';
  perform tests.eq((score_simulate_from_inputs(sim) #>> '{intake,main_meal_count}')::int, 0, '챌린지 없이: 100 kcal 은 간식이라 끼니 0개');
  perform tests.eq((score_simulate_from_inputs(sim || jsonb_build_object('challenge_id', v_new)) #>> '{intake,main_meal_count}')::int, 3, '챌린지 id 를 주면 그 규칙(0)으로 끼니 3개');
  perform tests.ok(origin_trusted('com.android.healthconnect.phone.abc', (default_rules()).origin_whitelist), '휴대폰 센서 출처를 믿는다');
end $$;
rollback;
