-- 촬영 화면에서 '간식'을 고르면 간식 슬롯으로 저장(D55). 아침·점심·저녁은 서버 시각 그대로.
-- 미확정 간식 초안은 09:00 확정 때 1.3×AI 로만 자동 확정(대체값 하한 없음). 끼니 초안은 그대로 max(M_p, 1.3×AI).
begin;
-- 09:00 확정: 간식 초안은 하한 없이 1.3×AI, 끼니 초안은 max(M_p, 1.3×AI)
do $$
declare
  ji uuid := tests.pid('지수'); uid uuid := tests.uid('지수'); r jsonb; ph uuid; sn meals; bf meals; v_m numeric;
  rules challenge_rules := engine_rules((select challenge_id from participants where id = tests.pid('지수')));
begin
  v_m := m_p((select bmr_locked from participants where id = ji), rules);
  perform tests.ok(v_m > 260, 'M_p 가 1.3×200 보다 큼(시험 전제)');

  r := create_photo(uid, repeat('5a', 32), 400000, 1568, 1176, '2026-10-13 15:30+09', '2026-10-13 15:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('5a', 32), 400000, 1568, 1176, '2026-10-13 15:30+09');
  r := create_meal(uid, ph, false, '2026-10-13 15:31+09');
  update meals set slot = 'snack', status = 'draft', ai_kcal = 200 where id = (r ->> 'meal_id')::uuid;
  select * into sn from meals where id = (r ->> 'meal_id')::uuid;

  r := create_photo(uid, repeat('5b', 32), 400000, 1568, 1176, '2026-10-13 07:00+09', '2026-10-13 07:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('5b', 32), 400000, 1568, 1176, '2026-10-13 07:00+09');
  r := create_meal(uid, ph, false, '2026-10-13 07:01+09');
  update meals set status = 'draft', ai_kcal = 200 where id = (r ->> 'meal_id')::uuid;
  select * into bf from meals where id = (r ->> 'meal_id')::uuid;
  perform tests.eq(bf.slot::text, 'breakfast', '시험 전제: 끼니 초안은 아침');

  perform tests.ok(not coalesce((select is_final from daily_scores where participant_id = ji and local_date = '2026-10-13'), false),
    '시험 전제: 확정 전 날짜');
  perform compute_daily_score(ji, '2026-10-13', 'finalize');

  select * into sn from meals where id = sn.id;
  perform tests.eq(sn.status::text, 'auto', '간식 초안 자동 확정');
  perform tests.eq(sn.confirmed_kcal, 260::numeric, '간식 초안 = 1.3×AI(대체값 하한 없음)');
  perform tests.eq(sn.delta_ratio, 1.3::numeric, '간식 초안 delta_ratio = 1.3');
  select * into bf from meals where id = bf.id;
  perform tests.eq(bf.status::text, 'auto', '아침 초안 자동 확정');
  perform tests.eq(bf.confirmed_kcal, greatest(v_m, 260), '아침 초안 = max(M_p, 1.3×AI)');
  perform tests.eq(bf.delta_ratio, greatest(v_m, 260) / 200, '아침 초안 delta_ratio = max(M_p, 1.3×AI)/AI');
end $$;

-- 사진 끼니 만들기: p_snack 이면 간식 슬롯, 아니면 서버 시각 슬롯
do $$
declare
  uid uuid := tests.uid('지수'); r jsonb; ph uuid; m uuid;
begin
  r := create_photo(uid, repeat('6a', 32), 400000, 1568, 1176, '2026-10-13 07:00+09', '2026-10-13 07:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('6a', 32), 400000, 1568, 1176, '2026-10-13 07:00+09');
  r := create_meal(uid, ph, false, '2026-10-13 07:00+09', true); m := (r ->> 'meal_id')::uuid;
  perform tests.eq(r ->> 'slot', 'snack', '간식 선택 → 응답 슬롯 snack');
  perform tests.eq((select slot::text from meals where id = m), 'snack', '간식 선택 → 07:00 사진도 간식 슬롯');
  perform tests.ok((create_meal(uid, ph, false, '2026-10-13 07:01+09', true) ->> 'replayed')::boolean, '간식 재요청 → 기존 끼니(멱등)');

  r := create_photo(uid, repeat('6b', 32), 400000, 1568, 1176, '2026-10-13 07:00+09', '2026-10-13 07:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('6b', 32), 400000, 1568, 1176, '2026-10-13 07:00+09');
  r := create_meal(uid, ph, false, '2026-10-13 07:00+09');
  perform tests.eq(r ->> 'slot', 'breakfast', '선택 없음 → 서버 시각 슬롯(아침)');

  -- 인자 하나 더한 함수만 남고(PostgREST 이름 호출 모호성 없음), 권한은 service_role 만
  perform tests.ok(to_regprocedure('create_meal(uuid, uuid, boolean, timestamptz)') is null, '옛 4인자 create_meal 제거');
  perform tests.ok(has_function_privilege('service_role', 'create_meal(uuid, uuid, boolean, timestamptz, boolean, meal_slot)', 'execute'),
    'service_role 실행 가능');
  perform tests.ok(not has_function_privilege('authenticated', 'create_meal(uuid, uuid, boolean, timestamptz, boolean, meal_slot)', 'execute'),
    'authenticated 실행 불가');
  perform tests.ok(not has_function_privilege('anon', 'create_meal(uuid, uuid, boolean, timestamptz, boolean, meal_slot)', 'execute'),
    'anon 실행 불가');
end $$;
rollback;
