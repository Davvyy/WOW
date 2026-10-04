-- 포장 상품 후보 칩 순서(D66): 점검(제품 형태·핵심어·브랜드)에 밀린 상품은 밀리지 않은 상품 뒤로, 모두 밀렸으면 순서 그대로.
-- 마시는 질의면 같은 순서 칸 안에서 마시는 상품(ml·음료 분류) 먼저(자동·마시는 질의가 아니면 그대로)
begin;
insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, is_product, maker, unit_label) values
  -- 제품 형태: 브랜드(스타벅스 → NESTLE) 상품은 가루뿐, 마시는 카페라떼는 다른 회사 것만. 어느 쪽도 자동이 아니다
  ('P935-000000000-0101', '스타벅스 카페라테', '인스턴트커피', 100, 429, true, 'NESTLE UK LTD', '100g'),
  ('P935-000000000-0102', '카페라떼', '액상커피', 250, 170, true, '(주)테스트음료', '1개(250ml)'),
  -- 같은 이름·같은 점수의 과자(코드가 앞): 마시는 질의라 마시는 카페라떼보다 뒤
  ('P935-000000000-0100', '카페라떼', '초콜릿과자', 30, 117.6, true, '(주)테스트과자', '1회분(30g)'),
  -- 모두 가루: 브랜드 가루 → 다른 회사 가루(전과 같은 순서)
  ('P935-000000000-0201', '스타벅스 카푸치노', '인스턴트커피', 100, 429, true, 'NESTLE UK LTD', '100g'),
  ('P935-000000000-0202', '카푸치노 믹스', '인스턴트커피', 100, 410, true, '(주)테스트커피', '100g'),
  -- 핵심어: 브랜드(비비고 → 씨제이) 상품은 김치가 꾸밈말인 김치덮밥뿐, 김치는 다른 회사 것만
  ('P935-000000000-0301', '습 김치덮밥', '즉석밥', 252, 340.2, true, '씨제이제일제당주식회사', '1개(252g)'),
  ('P935-000000000-0302', '김치', '배추김치', 40, 12, true, '(주)테스트김치', '1회분(40g)'),
  -- 자동은 그대로: 브랜드(빙그레) 마시는 제품이 있으면 그 상품 자동, 첫 칩도 그 상품
  ('P935-000000000-0401', '빙그레 바나나맛우유', '가공유', 240, 208, true, '(주)빙그레', '1개(240ml)'),
  ('P935-000000000-0402', '바나나맛우유', '가공유', 200, 150, true, '(주)테스트유업', '1개(200ml)'),
  ('P935-000000000-0403', '빙그레 바나나맛우유 분말', '분말음료', 100, 420, true, '(주)빙그레', '100g'),
  -- 점수가 약한 상품은 올리지 않는다: 같은 이름 원두분말(점수 1)이 약하게 비슷한 마시는 제품(0.32)보다 먼저
  ('P935-000000000-0501', '카누 아메리카노', '원두/원두분말', 108, 300.2, true, '동서식품(주)', '1개(108g)'),
  ('P935-000000000-0502', '맥심 티.오.피 콜드브루 아메리카노', '액상커피', 275, 8.3, true, '동서식품(주)', '1개(275ml)'),
  -- 마시는 질의가 아니면 같은 점수의 ml 상품을 올리지 않는다(쿠키 → 과자 먼저, 코드 순서 그대로)
  ('P935-000000000-0601', '초코 쿠키', '비스킷/쿠키/크래커', 30, 150, true, '(주)테스트과자', '1개(30g)'),
  ('P935-000000000-0602', '초코 쿠키', '아이스크림', 140, 700, true, '(주)테스트빙과', '1개(140ml)'),
  -- 마시는 질의라도 자동이면 첫 칩 = 고른 상품(같은 점수의 마시는 상품이 앞서지 않음)
  ('P935-000000000-0701', '딸기 스무디', '빙과', 100, 150, true, '(주)테스트빙과', '100g'),
  ('P935-000000000-0702', '딸기 스무디', '과·채음료', 300, 450, true, '(주)테스트음료', '1개(300ml)');

do $$
declare r jsonb; p jsonb; i0 int; i1 int;
begin
  -- ---------------- 가루에 밀린 브랜드 상품보다 다른 회사 마시는 제품이 첫 칩
  p := map_food_pick(array['스타벅스 카페라떼', '카페라떼'], true);
  perform tests.eq(p ->> 'match', 'chips', '형태: 상품 결과는 후보 칩');
  perform tests.ok(abs((p ->> 'score')::numeric - 0.636) < 0.01, '형태: 점수는 고른 상품(가루) 그대로');
  r := map_food_candidates(array['스타벅스 카페라떼', '카페라떼'], true);
  perform tests.eq(r ->> 'match', 'chips', '형태: 후보 칩(자동 아님)');
  perform tests.ok(r ->> 'food_code' is null, '형태: 확정 코드 없음');
  perform tests.eq((r ->> 'demoted')::boolean, true, '형태: demoted 표시 그대로');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P935-000000000-0102', '형태: 첫 칩 = 마시는 카페라떼(250ml)');
  perform tests.eq(r -> 'chips' -> 1 ->> 'food_code', 'P935-000000000-0100', '마시는 질의: 같은 이름·점수의 과자는 마시는 카페라떼 뒤');
  perform tests.eq(r -> 'chips' -> 2 ->> 'food_code', 'P935-000000000-0101', '형태: 가루는 그 뒤');

  -- ---------------- 모두 밀렸으면(모두 가루) 순서 그대로
  r := map_food_pick(array['스타벅스 카푸치노', '카푸치노'], true);
  perform tests.eq(r ->> 'match', 'chips', '모두 가루: 후보 칩');
  -- 위 '스타벅스 카페라테' 가루도 같은 브랜드 가루로 든다: 브랜드 가루(점수 순) → 다른 회사 가루, 전과 같은 순서
  perform tests.eq((select array_agg(e ->> 'food_code' order by n) from jsonb_array_elements(r -> 'chips') with ordinality t(e, n)),
    array['P935-000000000-0201', 'P935-000000000-0101', 'P935-000000000-0202'], '모두 가루: 순서 그대로(브랜드 가루 → 다른 회사 가루)');

  -- ---------------- 핵심어가 꾸밈말인 브랜드 상품보다 다른 회사 김치가 첫 칩
  r := map_food_pick(array['비비고 김치', '김치'], true);
  perform tests.eq(r ->> 'match', 'chips', '핵심어: 후보 칩');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P935-000000000-0302', '핵심어: 첫 칩 = 김치');
  perform tests.eq(r -> 'chips' -> 1 ->> 'food_code', 'P935-000000000-0301', '핵심어: 김치덮밥은 그 뒤');

  -- ---------------- 자동은 그대로, 다른 회사 상품은 브랜드로 밀려 브랜드 가루보다도 뒤
  r := map_food_pick(array['빙그레 바나나맛우유', '바나나맛우유'], true);
  perform tests.eq(r ->> 'match', 'auto', '자동: 그대로');
  perform tests.eq(r ->> 'food_code', 'P935-000000000-0401', '자동: 브랜드 마시는 제품');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P935-000000000-0401', '자동: 첫 칩 = 고른 상품');
  select min(n) filter (where e ->> 'food_code' = 'P935-000000000-0403'), min(n) filter (where e ->> 'food_code' = 'P935-000000000-0402')
    into i0, i1 from jsonb_array_elements(r -> 'chips') with ordinality t(e, n);
  perform tests.ok(i0 is not null and i1 is not null and i0 < i1, '자동: 브랜드가 맞는 상품이 있으면 다른 회사 상품은 밀린 상품(가루 뒤 그대로)');

  -- ---------------- 점수가 약한(0.45 미만) 밀리지 않은 상품은 앞으로 오지 않는다
  r := map_food_pick(array['동서 맥심 카누 아메리카노', '맥심 카누 아메리카노'], true);
  perform tests.eq(r ->> 'match', 'chips', '약한 후보: 후보 칩(원두분말이라 자동 아님)');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P935-000000000-0501', '약한 후보: 첫 칩 = 카누 아메리카노(전과 같음)');
  perform tests.ok((select (e ->> 'score')::numeric < 0.45 from jsonb_array_elements(r -> 'chips') e where e ->> 'food_code' = 'P935-000000000-0502'),
    '약한 후보: 티오피 콜드브루 점수는 0.45 미만');

  -- ---------------- 마시는 질의가 아니면 그대로, 자동이면 첫 칩 = 고른 상품
  r := map_food_pick(array['롯데 초코 쿠키', '초코 쿠키'], true);
  perform tests.eq(r ->> 'match', 'chips', '마시지 않는 질의: 후보 칩(브랜드 상품 없음)');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P935-000000000-0601', '마시지 않는 질의: 첫 칩 = 과자(ml 아이스크림을 올리지 않음)');
  perform tests.eq(r -> 'chips' -> 1 ->> 'food_code', 'P935-000000000-0602', '마시지 않는 질의: 아이스크림은 그 뒤');
  r := map_food_pick(array['딸기 스무디'], true);
  perform tests.eq(r ->> 'match', 'auto', '마시는 질의 자동: 자동');
  perform tests.eq(r ->> 'food_code', 'P935-000000000-0701', '마시는 질의 자동: 고른 상품 그대로');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P935-000000000-0701', '마시는 질의 자동: 첫 칩 = 고른 상품');
end $$;

-- 권한은 그대로: map_product_pick 은 참가자가 못 부른다
set local role authenticated;
do $$ begin
  perform tests.throws($q$select map_product_pick(array['카페라떼'])$q$, '42501', '권한: map_product_pick 은 참가자 호출 불가');
end $$;
reset role;
rollback;
