-- 조각 수 가드(D73): 조각 수를 그릇 수로 낸 것으로 보고 인분으로 바꾼 AI 초안 항목은 meal_items.ai_piece_guard = true(기본 false).
begin;
do $$
begin
  perform tests.eq((select column_default from information_schema.columns where table_name = 'meal_items' and column_name = 'ai_piece_guard'),
    'false', '기본값 false');
  perform tests.eq((select is_nullable from information_schema.columns where table_name = 'meal_items' and column_name = 'ai_piece_guard'),
    'NO', 'null 불가');
  perform tests.eq((select data_type from information_schema.columns where table_name = 'meal_items' and column_name = 'ai_piece_guard'),
    'boolean', 'boolean');
end $$;

-- 음식 매칭은 1인분 g·분류도 준다(자동 매칭 최상위 + 후보 칩마다) — 가드는 접시 크기·조각 음식만 본다
insert into food_db_cache (food_code, name_kr, category, serving_g, kcal) values
  ('D900401', '가드테스트초밥', '밥류', 300, 453), ('D900402', '가드테스트찐빵', '빵 및 과자류', 90, 300);
do $$
declare r jsonb;
begin
  r := map_food_candidates(array['가드테스트초밥'], false);
  perform tests.eq(r ->> 'match', 'auto', '자동 매칭');
  perform tests.eq((r ->> 'serving_g')::numeric, 300::numeric, '1인분 g');
  perform tests.eq(r ->> 'category', '밥류', '분류');
  perform tests.eq((select (c ->> 'serving_g')::numeric from jsonb_array_elements(r -> 'chips') c where c ->> 'food_code' = 'D900401'),
    300::numeric, '칩 1인분 g');
  perform tests.eq((select c ->> 'category' from jsonb_array_elements(r -> 'chips') c where c ->> 'food_code' = 'D900401'), '밥류', '칩 분류');
  r := map_food_candidates(array['가드테스트찐빵'], false);
  perform tests.eq((r ->> 'serving_g')::numeric, 90::numeric, '찐빵 1인분 g');
  r := map_food_candidates(array['어디에도없는음식이름'], false);
  perform tests.eq(r ->> 'match', 'none', '미매칭');
  perform tests.eq(r -> 'serving_g', 'null'::jsonb, '미매칭은 1인분 g 없음');
end $$;
rollback;
