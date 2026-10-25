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
rollback;
