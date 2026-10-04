-- 빈 끼니 칸 대체값 = max(M_p, 전날 같은 칸 등록 kcal)(D61). 전날 대체값은 쓰지 않고(연쇄 없음), 간식 칸은 그대로.
-- 전날이 바뀌면 recompute_day 가 다음 날 잠정 행도 다시 계산한다. 지수 10.14~10.16 은 시드 끼니가 없다.
begin;
do $$
declare
  uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수');
  ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
  v_m numeric; r jsonb; ph uuid; lunch uuid; snack uuid; b jsonb; d15 daily_scores;
begin
  v_m := m_p((select bmr_locked from participants where id = ji), engine_rules(ch));
  perform tests.ok(v_m < 900 and v_m > 200, format('지수 M_p %s 는 200 과 900 사이', v_m));

  -- 전날(10.14) 점심 사진 — 아직 분석 중(captured)이라 등록 kcal 이 아니다
  r := create_photo(uid, repeat('e1', 32), 400000, 1568, 1176, '2026-10-14 12:30+09', '2026-10-14 12:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('e1', 32), 400000, 1568, 1176, '2026-10-14 12:30+09');
  r := create_meal(uid, ph, false, '2026-10-14 12:30+09', p_slot => 'lunch'); lunch := (r ->> 'meal_id')::uuid;

  -- 오늘(10.15) 행: 세 칸 모두 비어 있음
  d15 := recompute_day(ji, '2026-10-15');
  b := d15.breakdown -> 'intake';
  perform tests.eq((b #>> '{substitute_values,lunch}')::numeric, v_m, '전날 점심이 분석 중이면 M_p');
  perform tests.eq((b #>> '{substitute_values,breakfast}')::numeric, v_m, '전날 기록 없음 → M_p');
  perform tests.eq(d15.i_d, r1(3 * v_m), '세 칸 모두 M_p');

  -- 전날 점심을 900 으로 확정 → 확정이 부른 recompute_day 가 오늘도 다시 계산
  update meals set status = 'draft', ai_kcal = 900 where id = lunch;
  perform confirm_meal(uid, lunch, '[{"chosen_name":"제육덮밥","serving_kcal":900,"eaten":true}]',
    (select version from meals where id = lunch), '2026-10-14 12:35+09');
  select * into d15 from daily_scores where participant_id = ji and local_date = '2026-10-15';
  b := d15.breakdown -> 'intake';
  perform tests.eq((b #>> '{substitute_values,lunch}')::numeric, 900::numeric, '전날 점심 900 → 오늘 점심 대체값 900');
  perform tests.eq((b #>> '{substitute_values,dinner}')::numeric, v_m, '전날 저녁 없음 → M_p');
  perform tests.eq(d15.i_d, r1(2 * v_m + 900), 'I_d = M_p × 2 + 900');
  perform tests.eq((b ->> 'm_p')::numeric, v_m, 'm_p 는 그대로');
  perform tests.ok((b -> 'substitute_slots') ? 'lunch', '점심은 여전히 대체 칸');
  perform tests.eq((d15.breakdown #>> '{inputs,prev_slots,lunch}')::numeric, 900::numeric, '입력에 전날 칸 kcal');

  -- 연쇄 없음: 10.16 점심은 10.15 의 대체값(900)이 아니라 10.15 등록 기록(없음) 기준
  b := (recompute_day(ji, '2026-10-16')).breakdown -> 'intake';
  perform tests.eq((b #>> '{substitute_values,lunch}')::numeric, v_m, '전날 대체값은 다음 날로 이어지지 않음');

  -- 오늘 점심이 분석 중(pending)이어도 같은 값
  r := create_photo(uid, repeat('e2', 32), 400000, 1568, 1176, '2026-10-15 12:30+09', '2026-10-15 12:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('e2', 32), 400000, 1568, 1176, '2026-10-15 12:30+09');
  perform create_meal(uid, ph, false, '2026-10-15 12:30+09', p_slot => 'lunch');
  select * into d15 from daily_scores where participant_id = ji and local_date = '2026-10-15';
  b := d15.breakdown -> 'intake';
  perform tests.ok((b -> 'pending_slots') ? 'lunch', '오늘 점심 분석 중');
  perform tests.eq((b #>> '{substitute_values,lunch}')::numeric, 900::numeric, '분석 중 칸도 전날 900');
  perform tests.eq(d15.i_d, r1(2 * v_m + 900), '분석 중 칸 I_d');
  delete from meals where participant_id = ji and local_date = '2026-10-15';

  -- 건너뜀: 한도 안(아침)은 0, 한도 초과(점심)는 max(M_p, 전날)
  insert into meals (participant_id, challenge_id, local_date, slot, status) values
    (ji, ch, '2026-10-15', 'breakfast', 'skipped'), (ji, ch, '2026-10-15', 'lunch', 'skipped');
  d15 := recompute_day(ji, '2026-10-15');
  b := d15.breakdown -> 'intake';
  perform tests.ok((b ->> 'skip_over')::boolean, '하루 두 번째 건너뜀은 한도 초과');
  perform tests.ok(not (b -> 'substitute_values' ? 'breakfast'), '한도 안 건너뜀은 대체값 없음');
  perform tests.eq((b #>> '{substitute_values,lunch}')::numeric, 900::numeric, '한도 초과 건너뜀도 전날 900');
  perform tests.eq(d15.i_d, r1(v_m + 900), '건너뜀 I_d = 0 + 900 + M_p');
  delete from meals where participant_id = ji and local_date = '2026-10-15';
  perform recompute_day(ji, '2026-10-15');

  -- 전날 간식 1000 은 오늘 어느 칸에도 영향 없음, 간식 칸엔 대체값이 없다
  insert into meals (participant_id, challenge_id, local_date, slot, status, confirmed_kcal) values
    (ji, ch, '2026-10-14', 'snack', 'confirmed', 1000) returning id into snack;
  perform recompute_day(ji, '2026-10-14');
  select * into d15 from daily_scores where participant_id = ji and local_date = '2026-10-15';
  b := d15.breakdown -> 'intake';
  perform tests.ok(not (b -> 'substitute_values' ? 'snack'), '간식 칸 대체값 없음');
  perform tests.eq(d15.i_d, r1(2 * v_m + 900), '전날 간식은 오늘 I_d 에 영향 없음');
  delete from meals where id = snack;

  -- 전날 점심을 200 으로 고침(M_p 미만) → 연쇄로 오늘 점심 M_p
  perform confirm_meal(uid, lunch, '[{"chosen_name":"샐러드","serving_kcal":200,"eaten":true}]',
    (select version from meals where id = lunch), '2026-10-14 12:40+09');
  select * into d15 from daily_scores where participant_id = ji and local_date = '2026-10-15';
  perform tests.eq((d15.breakdown #>> '{intake,substitute_values,lunch}')::numeric, v_m, '전날 점심 200 → M_p');
  perform tests.eq(d15.i_d, r1(3 * v_m), '다시 M_p × 3');

  -- 확정된 다음 날은 연쇄로 바뀌지 않는다
  update meals set confirmed_kcal = 900 where id = lunch;
  update daily_scores set is_final = true where participant_id = ji and local_date = '2026-10-15';
  perform recompute_day(ji, '2026-10-14');
  perform tests.eq((select i_d from daily_scores where participant_id = ji and local_date = '2026-10-15'), r1(3 * v_m),
    '확정된 다음 날은 그대로');
  update daily_scores set is_final = false where participant_id = ji and local_date = '2026-10-15';

  -- 점검 시작 전 날은 전날로 보지 않는다
  update participants set check_start = '2026-10-15' where id = ji;
  d15 := recompute_day(ji, '2026-10-15');
  perform tests.eq((d15.breakdown #>> '{intake,substitute_values,lunch}')::numeric, v_m, '점검 시작 전 날은 전날 아님 → M_p');
end $$;
rollback;

-- 시뮬레이터: prev_slots 를 주면 같은 규칙, 안 주면 예전과 같다(대체값 표 없음)
do $$
declare
  base jsonb := jsonb_build_object('bmr', 1650, 'weight_kg', 70, 'meals', '[]'::jsonb);
  a jsonb; b jsonb;
begin
  a := score_simulate_from_inputs(base);
  b := score_simulate_from_inputs(base || '{"prev_slots":{"lunch":900,"dinner":200,"snack":5000}}');
  perform tests.ok(not ((a -> 'intake') ? 'substitute_values'), 'prev_slots 없으면 결과 모양 그대로');
  perform tests.eq((a #>> '{intake,i_d}')::numeric, 2227.5, 'prev_slots 없음: M_p × 3');
  perform tests.eq((b #>> '{intake,i_d}')::numeric, 2385.0, 'prev_slots: 742.5 + 900 + 742.5');
  perform tests.eq((b #>> '{intake,substitute_values,lunch}')::numeric, 900::numeric, '시뮬레이터 점심 900');
  perform tests.ok(not ((b -> 'intake' -> 'substitute_values') ? 'snack'), '시뮬레이터 간식 무시');
  perform tests.ok(has_function_privilege('authenticated', 'intake_kcal(int, jsonb, int, challenge_rules, jsonb)', 'execute'),
    'authenticated 실행 가능');
  perform tests.ok(not has_function_privilege('anon', 'intake_kcal(int, jsonb, int, challenge_rules, jsonb)', 'execute'),
    'anon 실행 불가');
  perform tests.ok(not exists (select 1 from pg_proc where proname = 'intake_kcal' and pronargs = 4), '옛 4인자 intake_kcal 제거');
end $$;
