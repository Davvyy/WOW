-- 끼니 칸 기록을 간식 기준(150 kcal) 미만으로 확정하면 간식 칸으로 옮긴다(D59). 원래 칸은 main_slot 에 남겨,
-- 나중에 150 이상으로 고치면 원래 칸으로 되돌린다. 점수는 옮기기 전과 같다(간식 수준 기록은 원래 칸을 채우지 않음).
begin;
do $$
declare
  uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); r jsonb; ph uuid; m uuid; mm meals; i_before numeric;
  coffee jsonb := '[{"chosen_name":"아메리카노","serving_kcal":11,"eaten":true}]';
  dinner jsonb := '[{"chosen_name":"비빔밥","serving_kcal":600,"eaten":true}]';
begin
  r := create_photo(uid, repeat('c1', 32), 400000, 1568, 1176, '2026-10-13 19:00+09', '2026-10-13 19:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('c1', 32), 400000, 1568, 1176, '2026-10-13 19:00+09');
  r := create_meal(uid, ph, false, '2026-10-13 19:00+09', p_slot => 'dinner'); m := (r ->> 'meal_id')::uuid;
  update meals set status = 'draft', ai_kcal = 11 where id = m;

  r := confirm_meal(uid, m, coffee, (select version from meals where id = m), '2026-10-13 19:05+09');
  select * into mm from meals where id = m;
  perform tests.eq(mm.slot::text, 'snack', '11 kcal 저녁 → 간식 칸');
  perform tests.eq(mm.main_slot::text, 'dinner', '원래 칸은 main_slot 에');
  perform tests.eq(r ->> 'slot', 'snack', '응답에 옮긴 칸');
  i_before := (select i_d from daily_scores where participant_id = ji and local_date = '2026-10-13');

  -- 150 이상으로 고치면 원래 칸으로
  r := confirm_meal(uid, m, dinner, (select version from meals where id = m), '2026-10-13 19:10+09');
  select * into mm from meals where id = m;
  perform tests.eq(mm.slot::text, 'dinner', '600 kcal 로 고치면 저녁 칸으로 되돌림');
  perform tests.ok(mm.main_slot is null, 'main_slot 비움');
  perform tests.eq(r ->> 'slot', 'dinner', '응답에 되돌린 칸');

  -- 다시 간식 수준으로 → 간식, 점수(섭취)는 처음 간식 수준일 때와 같다
  r := confirm_meal(uid, m, coffee, (select version from meals where id = m), '2026-10-13 19:15+09');
  perform tests.eq((select slot::text from meals where id = m), 'snack', '다시 간식 칸');
  perform tests.eq((select i_d from daily_scores where participant_id = ji and local_date = '2026-10-13'), i_before, '섭취 계산 동일');

  -- 처음부터 간식으로 고른 기록은 크게 고쳐도 간식 그대로
  r := create_photo(uid, repeat('c2', 32), 400000, 1568, 1176, '2026-10-13 15:00+09', '2026-10-13 15:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('c2', 32), 400000, 1568, 1176, '2026-10-13 15:00+09');
  r := create_meal(uid, ph, false, '2026-10-13 15:00+09', p_slot => 'snack'); m := (r ->> 'meal_id')::uuid;
  update meals set status = 'draft', ai_kcal = 600 where id = m;
  r := confirm_meal(uid, m, dinner, (select version from meals where id = m), '2026-10-13 15:05+09');
  perform tests.eq((select slot::text from meals where id = m), 'snack', '간식으로 고른 기록은 간식 그대로');

  -- 직접 입력(사진 없는 기록)도 같은 규칙
  r := create_manual_meal(uid, 'lunch', coffee, '2026-10-13', '2026-10-13 12:00+09');
  perform tests.eq((select slot::text from meals where id = (r ->> 'meal_id')::uuid), 'snack', '직접 입력 11 kcal 점심 → 간식');
end $$;
rollback;
