-- 촬영 화면에서 고른 끼니(아침·점심·저녁·간식)로 저장한다(D58). 고르지 않으면 서버 시각 슬롯.
-- 서버 시각 슬롯은 time_slot 에 남겨 운영자가 고른 끼니와 비교할 수 있다.
begin;
do $$
declare
  uid uuid := tests.uid('지수'); r jsonb; ph uuid; m uuid; i int := 0; s text;
begin
  -- 09:14 KST 사진(서버 시각으로는 아침)
  foreach s in array array['lunch', 'dinner', 'breakfast', 'snack'] loop
    i := i + 1;
    r := create_photo(uid, repeat(to_hex(160 + i), 32), 400000, 1568, 1176, '2026-10-13 09:14+09', '2026-10-13 09:14+09'); ph := (r ->> 'photo_id')::uuid;
    perform verify_photo(uid, ph, repeat(to_hex(160 + i), 32), 400000, 1568, 1176, '2026-10-13 09:14+09');
    r := create_meal(uid, ph, false, '2026-10-13 09:14+09', p_slot => s::meal_slot); m := (r ->> 'meal_id')::uuid;
    perform tests.eq(r ->> 'slot', s, '고른 끼니로 응답: ' || s);
    perform tests.eq((select slot::text from meals where id = m), s, '고른 끼니로 저장: ' || s);
    perform tests.eq((select time_slot::text from meals where id = m), 'breakfast', '서버 시각 슬롯은 따로 남김: ' || s);
  end loop;

  -- 고르지 않으면 서버 시각
  r := create_photo(uid, repeat('b1', 32), 400000, 1568, 1176, '2026-10-13 13:00+09', '2026-10-13 13:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('b1', 32), 400000, 1568, 1176, '2026-10-13 13:00+09');
  r := create_meal(uid, ph, false, '2026-10-13 13:00+09');
  perform tests.eq(r ->> 'slot', 'lunch', '선택 없음 → 서버 시각 슬롯(점심)');

  -- 옛 호출(p_snack)도 그대로 간식(배포 사이 호환)
  r := create_photo(uid, repeat('b2', 32), 400000, 1568, 1176, '2026-10-13 13:00+09', '2026-10-13 13:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('b2', 32), 400000, 1568, 1176, '2026-10-13 13:00+09');
  r := create_meal(uid, ph, false, '2026-10-13 13:00+09', true);
  perform tests.eq(r ->> 'slot', 'snack', 'p_snack 참 → 간식');

  perform tests.ok(to_regprocedure('create_meal(uuid, uuid, boolean, timestamptz, boolean)') is null, '옛 5인자 create_meal 제거');
  perform tests.ok(has_function_privilege('service_role', 'create_meal(uuid, uuid, boolean, timestamptz, boolean, meal_slot)', 'execute'),
    'service_role 실행 가능');
  perform tests.ok(not has_function_privilege('authenticated', 'create_meal(uuid, uuid, boolean, timestamptz, boolean, meal_slot)', 'execute'),
    'authenticated 실행 불가');
end $$;
rollback;
