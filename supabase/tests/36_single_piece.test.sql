-- 낱개 포장 한 개(D67): AI 가 낱개 봉지 하나로 본 포장 상품 항목은 meal_items.ai_single_piece = true(기본 false).
-- '몇 개입'으로 1개 단위로 바꾼 것은 단위 정정이라, 확정 전에 AI 초안을 같은 단위로 맞춰 하향 수정 표시(downward_edit)를 올리지 않는다.
begin;
insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, is_product, maker, unit_label, package_g) values
  ('P900-000000000-3601', '칙촉', '비스킷/쿠키/크래커', 30, 150.3, true, '롯데제과(주)', '1회분(30g)', 180),
  ('D900361', '흰쌀밥', '밥류', 210, 310, false, null, null, null);

-- 칸: 기본 false, null 불가
do $$
begin
  perform tests.eq((select column_default from information_schema.columns where table_name = 'meal_items' and column_name = 'ai_single_piece'),
    'false', '기본값 false');
  perform tests.eq((select is_nullable from information_schema.columns where table_name = 'meal_items' and column_name = 'ai_single_piece'),
    'NO', 'null 불가');
end $$;

-- 지수의 간식 초안: 칙촉 낱개 봉지(1회분 150.3, ai_single_piece) [+ 흰쌀밥 310 → AI 460.3]
create temp table t_meal (k text primary key, id uuid);
grant all on t_meal to public;
create or replace function pg_temp.draft(p_key text, p_shot text, p_rice boolean default true) returns uuid language plpgsql as $$
declare uid uuid := tests.uid('지수'); r jsonb; ph uuid; m uuid;
begin
  r := create_photo(uid, repeat(p_shot, 32), 400000, 1568, 1176, '2026-10-14 12:30+09', '2026-10-14 12:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat(p_shot, 32), 400000, 1568, 1176, '2026-10-14 12:30+09');
  r := create_meal(uid, ph, false, '2026-10-14 12:30+09', p_slot => 'snack'); m := (r ->> 'meal_id')::uuid;
  insert into meal_items (meal_id, name_candidates, chosen_name, food_code, input_type, count, portion_multiplier, ai_kcal, serving_kcal,
    candidate_kcal, candidate_food_codes, ai_single_piece) values
    (m, '{칙촉}', '칙촉', 'P900-000000000-3601', 'ai', 1, 1.0, 150.3, 150.3, '{150.3}', '{P900-000000000-3601}', true);
  if p_rice then
    insert into meal_items (meal_id, name_candidates, chosen_name, food_code, input_type, count, portion_multiplier, ai_kcal, serving_kcal)
      values (m, '{흰쌀밥}', '흰쌀밥', 'D900361', 'ai', 1, 1.0, 310, 310);
  end if;
  update meals set status = 'draft', ai_kcal = case when p_rice then 460.3 else 150.3 end where id = m;
  insert into t_meal values (p_key, m);
  return m;
end $$;

-- 앱이 보내는 확정 항목: 칙촉 [serving] kcal × [n]개 [+ 흰쌀밥 310]
create or replace function pg_temp.items(p_serving numeric, p_n int default 1, p_rice boolean default true) returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('chosen_name', '칙촉', 'food_code', 'P900-000000000-3601', 'serving_kcal', p_serving, 'candidate_kcal', jsonb_build_array(p_serving),
      'name_candidates', jsonb_build_array('칙촉'), 'count', p_n, 'portion_multiplier', 1.0, 'eaten', true, 'input_type', 'ai'),
    jsonb_build_object('chosen_name', '흰쌀밥', 'food_code', 'D900361', 'serving_kcal', 310, 'name_candidates', jsonb_build_array('흰쌀밥'),
      'count', 1, 'portion_multiplier', 1.0, 'eaten', true, 'input_type', 'ai')) - case when p_rice then 99 else 1 end
$$;

do $$
declare m uuid := pg_temp.draft('a', 'a1'); d uuid;
begin
  perform tests.eq((select array_agg(ai_single_piece order by food_code) from meal_items where meal_id = m), array[false, true], '저장: 칙촉만 true');
  insert into meal_items (meal_id, chosen_name, ai_kcal) values (m, '김', 70) returning id into d;
  perform tests.eq((select ai_single_piece from meal_items where id = d), false, '저장: 칸을 빼면 false');
  delete from meal_items where id = d;
end $$;

-- 개입 수 없이 1개 kcal 로 낮춘 것은 단위 정정이 아니다: 맞추지 않고 하향 수정 표시(37.6 / 150.3)
do $$
declare uid uuid := tests.uid('지수'); m uuid := pg_temp.draft('none', 'a2', false); r jsonb; v int;
begin
  v := (select version from meals where id = m);
  perform tests.eq(rebase_ai_kcal_for_pieces(uid, m, pg_temp.items(37.6, 1, false), v), 150.3, '개입 수 없음: AI 그대로');
  r := confirm_meal(uid, m, pg_temp.items(37.6, 1, false), v, '2026-10-14 12:40+09');
  perform tests.ok(r -> 'flags' ? 'downward_edit', '개입 수 없음: 하향 수정 표시');
end $$;

-- 지수가 24개입을 넣음 → 칙촉 1개 37.6
insert into user_product_pieces (user_id, food_code, pieces) values (tests.uid('지수'), 'P900-000000000-3601', 24);

do $$
declare uid uuid := tests.uid('지수'); m uuid := pg_temp.draft('b', 'a3'); r jsonb; v int;
begin
  v := (select version from meals where id = m);
  -- 남의 끼니·버전 불일치는 손대지 않는다
  perform tests.ok(rebase_ai_kcal_for_pieces(tests.uid('밤산책'), m, pg_temp.items(37.6), v) is null, '남의 끼니: 맞추지 않음');
  perform tests.ok(rebase_ai_kcal_for_pieces(uid, m, pg_temp.items(37.6), v + 1) is null, '버전 불일치: 맞추지 않음');
  -- 1회분 그대로 확정하면 바꿀 것 없음
  perform tests.eq(rebase_ai_kcal_for_pieces(uid, m, pg_temp.items(150.3), v), 460.3, '1회분 그대로: AI 그대로');
  -- 1개 단위로 확정: 칙촉 AI 150.3 → 37.6 × 1, 끼니 AI 347.6
  perform tests.eq(rebase_ai_kcal_for_pieces(uid, m, pg_temp.items(37.6), v), 347.6, '1개 단위: 끼니 AI 347.6');
  perform tests.eq((select ai_kcal from meal_items where meal_id = m and chosen_name = '칙촉'), 37.6, '1개 단위: 항목 AI 37.6');
  perform tests.eq((select ai_kcal from meal_items where meal_id = m and chosen_name = '흰쌀밥'), 310::numeric, '음식 항목은 그대로');
  perform tests.eq((select version from meals where id = m), v, '버전은 그대로(확정이 올린다)');
  perform tests.eq(rebase_ai_kcal_for_pieces(uid, m, pg_temp.items(37.6), v), 347.6, '다시 불러도 같음');
end $$;

-- 칙촉 낱개 봉지 하나만 찍은 실제 사례: 150.3 → 37.6 을 맞춘 뒤 확정하면 하향 수정 표시 없음
do $$
declare uid uuid := tests.uid('지수'); m uuid := pg_temp.draft('d', 'a5', false); r jsonb; v int;
begin
  v := (select version from meals where id = m);
  perform tests.eq(rebase_ai_kcal_for_pieces(uid, m, pg_temp.items(37.6, 1, false), v), 37.6, '칙촉만: 끼니 AI 37.6');
  r := confirm_meal(uid, m, pg_temp.items(37.6, 1, false), v, '2026-10-14 12:40+09');
  perform tests.eq((r ->> 'confirmed_kcal')::numeric, 37.6, '확정 37.6');
  perform tests.eq((r ->> 'delta_ratio')::numeric, 1::numeric, 'AI 대비 1.0');
  perform tests.ok(not (r -> 'flags' ? 'downward_edit'), '단위 정정은 하향 수정 표시 없음');
  perform tests.eq((select count(*)::int from reviews where target ->> 'meal_id' = m::text and type = 'downward_edit'), 0, '검토 행 없음');
  perform tests.eq((select bool_or(ai_single_piece) from meal_items where meal_id = m), false, '확정한 항목은 낱개 표시를 남기지 않음');
  -- 확정한 끼니는 맞추지 않는다
  perform tests.ok(rebase_ai_kcal_for_pieces(uid, m, pg_temp.items(37.6, 1, false), v + 1) is null, '확정한 끼니: 맞추지 않음');
end $$;

-- 1개 단위로 바꿨어도 개수를 AI 보다 크게 줄이면(칙촉 3봉지 → 1개) 하향 수정은 그대로 본다
do $$
declare uid uuid := tests.uid('지수'); m uuid := pg_temp.draft('c', 'a4', false); r jsonb; v int;
begin
  update meal_items set count = 3, ai_kcal = 450.9 where meal_id = m;
  update meals set ai_kcal = 450.9 where id = m;
  v := (select version from meals where id = m);
  perform tests.eq(rebase_ai_kcal_for_pieces(uid, m, pg_temp.items(37.6, 1, false), v), 112.8, '3봉지: AI 37.6 × 3 = 112.8');
  r := confirm_meal(uid, m, pg_temp.items(37.6, 1, false), v, '2026-10-14 12:45+09');
  perform tests.ok(r -> 'flags' ? 'downward_edit', '1개만 남기면 37.6 / 112.8 → 표시');
end $$;

-- 서비스 전용
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
begin
  perform tests.throws(format('select rebase_ai_kcal_for_pieces(%L, %L, %L, 1)', tests.uid('지수'), (select id from t_meal where k = 'b'), '[]'),
    '42501', '참가자 호출 불가');
end $$;
reset role;
rollback;
