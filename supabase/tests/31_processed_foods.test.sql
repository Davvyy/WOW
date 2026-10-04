-- 가공식품(상품) 행(D63): 일반 음식 자동 매칭에는 섞이지 않고, 포장 상품 매칭·검색에서만 나온다
begin;
insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, carb_g, protein_g, fat_g, is_product, maker, unit_label) values
  ('P900-000000000-0001', '칙촉', '비스킷/쿠키/크래커', 30, 150.3, 18.3, 2, 7.7, true, '롯데웰푸드 주식회사', '1회분(30g)'),
  ('P900-000000000-0000', '칙촉', '비스킷/쿠키/크래커', 30, 140, 18, 2, 7, true, '다른제과(주)', '1회분(30g)'),
  ('P900-000000000-0002', '칙촉 브라우니', '초콜릿과자', 40, 190, 22, 3, 10, true, '롯데제과(주)', '1개(40g)'),
  ('P900-000000000-0003', '바나나우유', '가공유', 240, 208, null, null, null, true, '빙그레', '1개(240ml)'),
  ('D900001', '초코칩쿠키', '과자류', 70, 308, null, null, null, false, null, null),
  ('D900002', '바나나우유', '음료류', 200, 150, null, null, null, false, null, null);

do $$
declare r jsonb; s record; n int;
begin
  perform tests.eq((select is_product from food_db_cache where food_code = 'D000001'), false, '기존 음식 행은 is_product = false');

  -- 일반 음식 매칭(packaged 아님)은 상품을 돌려주지 않는다
  r := map_food_candidates(array['칙촉']);
  perform tests.eq(r ->> 'match', 'none', '음식 매칭: 상품 이름만 있으면 미매칭');
  perform tests.ok(r ->> 'food_code' is null, '음식 매칭: 상품 코드 없음');
  perform tests.eq(jsonb_array_length(r -> 'chips'), 0, '음식 매칭: 후보 칩에도 상품 없음');
  r := map_food_candidates(array['칙촉 브라우니', '바나나우유'], false);
  perform tests.eq(r ->> 'food_code', 'D900002', '음식 매칭: 같은 이름이면 음식 행');
  perform tests.ok(not exists (select 1 from jsonb_array_elements(r -> 'chips') e where e ->> 'food_code' like 'P%'), '음식 매칭: 칩에 상품 없음');

  -- 포장 상품 매칭: 상품 먼저(브랜드를 뗀 이름도), 같은 점수면 브랜드가 제조사에 든 상품
  r := map_food_candidates(array['롯데 칙촉', '초코칩쿠키'], true);
  perform tests.eq(r ->> 'match', 'auto', '상품 매칭: 자동');
  perform tests.eq(r ->> 'food_code', 'P900-000000000-0001', '상품 매칭: 브랜드 뗀 이름 칙촉, 제조사 롯데');
  perform tests.eq((r ->> 'kcal')::numeric, 150.3, '상품 매칭: 1개(1회분) kcal');
  perform tests.eq((r ->> 'is_product')::boolean, true, '상품 매칭: is_product 표시');
  r := map_food_candidates(array['칙촉'], true);
  perform tests.ok(r ->> 'food_code' like 'P900-000000000-000%', '상품 매칭: 브랜드 없이도 상품');
  -- 상품이 없으면 음식으로
  r := map_food_candidates(array['초코칩쿠키'], true);
  perform tests.eq(r ->> 'food_code', 'D900001', '상품 매칭: 상품이 없으면 음식으로');
  perform tests.eq((r ->> 'is_product')::boolean, false, '상품 매칭: 음식으로 내려가면 is_product = false');

  -- 검색: 음식과 상품 모두, 상품 표시·제조사·단위 라벨, 같은 점수면 음식 먼저
  select * into s from food_search('칙촉') where food_code = 'P900-000000000-0001';
  perform tests.eq(s.is_product, true, '검색: 상품 표시');
  perform tests.eq(s.maker, '롯데웰푸드 주식회사', '검색: 제조사');
  perform tests.eq(s.unit_label, '1회분(30g)', '검색: 단위 라벨');
  perform tests.eq(s.kcal, 150.3, '검색: 1개 kcal');
  select count(*) into n from food_search('칙촉') where is_product;
  perform tests.eq(n, 3, '검색: 칙촉 상품 3건');
  perform tests.eq((select array_agg(food_code) from (select food_code from food_search('바나나우유') limit 2) x),
    array['D900002', 'P900-000000000-0003'], '검색: 같은 점수면 음식 먼저');
  perform tests.eq((select is_product from food_search('흰쌀밥') limit 1), false, '검색: 음식 행은 is_product = false');
end $$;
rollback;
