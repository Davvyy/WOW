-- 확정해도 항목의 1인분 kcal·후보·국물 여부·먹음 여부가 남아, 다시 열었을 때 같은 값으로 보이고 다시 확정해도 합계가 같다.
begin;
do $$
declare
  uid uuid := tests.uid('지수'); r jsonb; ph uuid; m uuid; v int; it meal_items;
  items jsonb := '[
    {"chosen_name":"켈로그 첵스초코","name_candidates":["시리얼","켈로그 첵스초코","과자"],"candidate_kcal":[162,180,300],
     "candidate_food_codes":["D1",null,"D3"],"serving_kcal":180,"count":1,"portion_multiplier":1,"eaten":true,"has_broth":false},
    {"chosen_name":"된장국","name_candidates":["된장국"],"candidate_kcal":[100],"serving_kcal":100,"has_broth":true,"broth_off":true,"eaten":true},
    {"chosen_name":"김","name_candidates":["김"],"candidate_kcal":[70],"serving_kcal":70,"eaten":false},
    {"chosen_name":"직접 입력","serving_kcal":50,"input_type":"manual"}
  ]';
begin
  r := create_photo(uid, repeat('7a', 32), 400000, 1568, 1176, '2026-10-13 12:30+09', '2026-10-13 12:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('7a', 32), 400000, 1568, 1176, '2026-10-13 12:30+09');
  r := create_meal(uid, ph, false, '2026-10-13 12:31+09'); m := (r ->> 'meal_id')::uuid;
  insert into meal_items (meal_id, chosen_name, name_candidates, ai_kcal, serving_kcal, candidate_kcal)
  values (m, '시리얼', '{시리얼,켈로그 첵스초코,과자}', 162, 162, '{162,180,300}');
  update meals set status = 'draft', ai_kcal = 162 where id = m;

  r := confirm_meal(uid, m, items, (select version from meals where id = m), '2026-10-13 12:40+09');
  perform tests.eq((r ->> 'confirmed_kcal')::numeric, 290::numeric, '합계 = 180 + 60(국물 빼고) + 50, 안 먹은 김 제외');

  select * into it from meal_items where meal_id = m and chosen_name = '켈로그 첵스초코';
  perform tests.eq(it.serving_kcal, 180::numeric, '확정 후 1인분 kcal 유지');
  perform tests.eq(it.candidate_kcal, '{162,180,300}'::numeric[], '확정 후 후보 kcal 유지');
  perform tests.eq(it.candidate_food_codes, array['D1', null, 'D3'], '확정 후 후보 food_code 유지(없는 칸은 null)');
  perform tests.eq(it.confirmed_kcal, 180::numeric, '항목 확정 kcal');

  select * into it from meal_items where meal_id = m and chosen_name = '된장국';
  perform tests.ok(it.has_broth and it.broth_off, '국물 있는 음식 · 국물 안 먹음 유지');
  perform tests.eq(it.serving_kcal, 100::numeric, '국물 음식 1인분 kcal 유지');

  select * into it from meal_items where meal_id = m and chosen_name = '김';
  perform tests.ok(not it.eaten, '먹지 않음 유지');
  perform tests.eq(it.serving_kcal, 70::numeric, '먹지 않은 항목도 1인분 kcal 유지');

  select * into it from meal_items where meal_id = m and chosen_name = '직접 입력';
  perform tests.eq(it.serving_kcal, 50::numeric, '후보 없는 항목: 1인분 kcal 유지');
  perform tests.eq(it.candidate_kcal, '{}'::numeric[], '후보 kcal 없으면 빈 배열');
  perform tests.ok(not it.has_broth, '국물 표시 없으면 false');

  -- 저장된 항목 그대로 다시 확정 → 같은 합계(0 으로 떨어지지 않음)
  v := (select version from meals where id = m);
  r := confirm_meal(uid, m, (select jsonb_agg(jsonb_build_object('chosen_name', chosen_name, 'name_candidates', to_jsonb(name_candidates),
      'candidate_kcal', to_jsonb(candidate_kcal), 'serving_kcal', serving_kcal, 'count', count, 'portion_multiplier', portion_multiplier,
      'has_broth', has_broth, 'broth_off', broth_off, 'eaten', eaten)) from meal_items where meal_id = m), v, '2026-10-13 12:50+09');
  perform tests.eq((r ->> 'confirmed_kcal')::numeric, 290::numeric, '저장된 항목으로 다시 확정해도 290');
  perform tests.eq((select count(*)::int from reviews where target ->> 'meal_id' = m::text and type = 'downward_edit'), 0, '하향 수정 표시 없음');
end $$;
rollback;
