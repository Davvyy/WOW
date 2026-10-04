-- 먹은 양 0.1인분 단위(D60): portion_multiplier 0.1~3.0, kcal = 1인분 × 배수. 범위 밖은 check 위반(23514).
begin;
do $$
declare
  uid uuid := tests.uid('지수'); r jsonb; ph uuid; m uuid; mult numeric;
  item text := '[{"chosen_name":"라면","serving_kcal":450,"count":1,"portion_multiplier":%s,"eaten":true}]';
begin
  r := create_photo(uid, repeat('e1', 32), 400000, 1568, 1176, '2026-10-14 12:00+09', '2026-10-14 12:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('e1', 32), 400000, 1568, 1176, '2026-10-14 12:00+09');
  r := create_meal(uid, ph, false, '2026-10-14 12:00+09', p_slot => 'lunch'); m := (r ->> 'meal_id')::uuid;
  update meals set status = 'draft', ai_kcal = 450 where id = m;

  foreach mult in array array[0.1, 0.9, 1.2, 3.0]::numeric[]
  loop
    r := confirm_meal(uid, m, format(item, mult)::jsonb, (select version from meals where id = m), '2026-10-14 12:05+09');
    perform tests.eq((r ->> 'confirmed_kcal')::numeric, round(450 * mult, 1), format('%s인분 = 450 × %s', mult, mult));
    perform tests.eq((select portion_multiplier from meal_items where meal_id = m), mult, format('%s인분 저장', mult));
  end loop;
  perform tests.eq((select confirmed_kcal from meal_items where meal_id = m), 1350::numeric, '3.0인분 항목 kcal 1350');

  r := confirm_meal(uid, m, format(item, 1.2)::jsonb, (select version from meals where id = m), '2026-10-14 12:06+09');
  perform tests.eq((r ->> 'confirmed_kcal')::numeric, 540::numeric, '450 × 1.2 = 540');

  perform tests.throws(format('select confirm_meal(%L, %L, %L::jsonb, %s, %L)', uid, m, format(item, 0.05),
    (select version from meals where id = m), '2026-10-14 12:07+09'), '23514', '0.05인분은 범위 밖');
  perform tests.throws(format('select confirm_meal(%L, %L, %L::jsonb, %s, %L)', uid, m, format(item, 3.1),
    (select version from meals where id = m), '2026-10-14 12:07+09'), '23514', '3.1인분은 범위 밖');
  perform tests.eq((select confirmed_kcal from meals where id = m), 540::numeric, '거절된 확정은 값을 바꾸지 않음');
end $$;
rollback;
