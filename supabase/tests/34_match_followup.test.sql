-- 포장 상품 매칭 후속(D66): 점수는 충분한데 확인이 필요해 칩이 된(밀려난) 상품은 음식 자동 매칭보다 먼저, 약한 상품 후보는 전처럼 음식으로
begin;
insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, is_product, maker, unit_label) values
  -- 가루(제품 형태)에 밀린 상품: 마시는 '스타벅스 카페라떼'는 데이터에 없고 가루만 있다
  ('P934-000000000-0101', '스타벅스 카페라테', '인스턴트커피', 100, 429, true, 'NESTLE UK LTD', '100g'),
  ('D934101', '카페라떼', '음료 및 차류', 250, 134.9, false, null, null),
  -- 김치(D66 에서 절임류를 다시 넣음): 비비고 김치 → 씨제이 김치(김치덮밥·음식 김밥_김치가 아니라)
  ('P934-000000000-0201', '비비고 포기 배추김치', '배추김치', 40, 12, true, '씨제이제일제당(주)진천 BLOSSOM CAMPUS 4동', '1회분(40g)'),
  ('P934-000000000-0202', '습 김치덮밥', '밥류', 252, 340.2, true, '씨제이제일제당주식회사', '1개(252g)'),
  ('D934201', '김밥_김치', '김밥류', 250, 351, false, null, null),
  -- 브랜드에 밀린 상품: 브랜드(롯데) 제조사 상품이 없고 다른 회사의 같은 이름만 있다
  ('P934-000000000-0301', '마들렌 쇼콜라', '기타빵', 40, 180, true, '(주)다른제과', '1개(40g)'),
  ('D934301', '마들렌 쇼콜라', '빵류', 40, 175, false, null, null),
  -- 약한 상품 후보(점수 0.45 미만): 음식 자동 매칭으로
  ('P934-000000000-0401', '떡갈비구이', '즉석조리식품', 100, 250, true, '(주)고기회사', '100g'),
  ('D934401', '떡갈비', '구이류', 150, 380, false, null, null);

do $$
declare r jsonb; p jsonb;
begin
  -- ---------------- 밀려난 상품 후보 칩은 음식 자동 매칭보다 먼저
  p := map_food_pick(array['스타벅스 카페라떼', '카페라떼'], true);
  perform tests.eq(p ->> 'match', 'chips', '형태: 상품 결과는 후보 칩(가루라 자동 아님)');
  perform tests.ok((p ->> 'score')::numeric >= 0.45, '형태: 상품 점수는 0.45 이상(약한 매칭이 아님)');
  perform tests.eq((map_food_pick(array['스타벅스 카페라떼', '카페라떼'], false) ->> 'match'), 'auto', '형태: 음식 매칭만 보면 카페라떼 자동');
  r := map_food_candidates(array['스타벅스 카페라떼', '카페라떼'], true);
  perform tests.eq(r ->> 'match', 'chips', '형태: 스타벅스 카페라떼 → 음식 카페라떼 자동이 아니라 상품 후보 칩');
  perform tests.ok(r ->> 'food_code' is null, '형태: 확정 코드 없음');
  perform tests.eq((r ->> 'is_product')::boolean, true, '형태: is_product = true');
  perform tests.eq((r ->> 'demoted')::boolean, true, '형태: demoted 표시');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P934-000000000-0101', '형태: 첫 후보 칩 = 상품');
  perform tests.ok(not exists (select 1 from jsonb_array_elements(r -> 'chips') e where e ->> 'food_code' like 'D%'), '형태: 칩에 음식 행 없음');

  r := map_food_candidates(array['롯데 마들렌 쇼콜라', '마들렌 쇼콜라'], true);
  perform tests.eq(r ->> 'match', 'chips', '브랜드: 다른 회사 상품뿐이면 음식 자동이 아니라 상품 후보 칩');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P934-000000000-0301', '브랜드: 첫 후보 칩 = 다른 회사 상품');
  perform tests.eq((r ->> 'demoted')::boolean, true, '브랜드: demoted 표시');

  -- ---------------- 김치를 넣으면 비비고 김치 → 씨제이 김치 자동
  r := map_food_candidates(array['비비고 김치', '김치'], true);
  perform tests.eq(r ->> 'match', 'auto', '김치: 자동');
  perform tests.eq(r ->> 'food_code', 'P934-000000000-0201', '김치: 비비고 김치 → 씨제이 포기 배추김치(김치덮밥·김밥_김치 아님)');
  perform tests.eq((r ->> 'kcal')::numeric, 12::numeric, '김치: 1회분 kcal');
  perform tests.ok(r ->> 'demoted' is null, '김치: 자동이면 demoted 없음');

  -- ---------------- 약한 상품 후보는 전처럼 음식으로
  p := map_food_pick(array['떡갈비'], true);
  perform tests.eq(p ->> 'match', 'chips', '약한 상품: 상품 결과는 후보 칩');
  perform tests.ok((p ->> 'score')::numeric < 0.45, '약한 상품: 점수 0.45 미만');
  r := map_food_candidates(array['떡갈비'], true);
  perform tests.eq(r ->> 'match', 'auto', '약한 상품: 음식 자동 매칭으로');
  perform tests.eq((r ->> 'is_product')::boolean, false, '약한 상품: 음식 행');
  perform tests.ok(r ->> 'food_code' like 'D%', '약한 상품: 음식 코드');
  perform tests.ok(r ->> 'demoted' is null, '약한 상품: demoted 없음');

  -- ---------------- 포장 아님은 그대로 음식만
  r := map_food_candidates(array['스타벅스 카페라떼', '카페라떼'], false);
  perform tests.ok(r ->> 'match' = 'auto' and r ->> 'food_code' like 'D%', '포장 아님: 음식 카페라떼 자동');
  perform tests.ok(r ->> 'demoted' is null, '포장 아님: demoted 없음');
  r := map_food_candidates(array['스타벅스 카페라떼', '카페라떼']);
  perform tests.ok(r ->> 'match' = 'auto' and r ->> 'food_code' like 'D%', '포장 아님(기본값): 음식 카페라떼 자동');
end $$;

-- 권한은 그대로: 참가자는 map_food_candidates 만, 내부 함수는 못 부른다
set local role authenticated;
do $$ begin
  perform tests.ok(map_food_candidates(array['떡갈비'], true) is not null, '권한: 참가자는 map_food_candidates 호출 가능');
  perform tests.throws($q$select map_food_pick(array['떡갈비'], true)$q$, '42501', '권한: map_food_pick 은 참가자 호출 불가');
end $$;
reset role;
set local role anon;
do $$ begin
  perform tests.throws($q$select map_food_candidates(array['떡갈비'], true)$q$, '42501', '권한: 익명은 map_food_candidates 호출 불가');
end $$;
reset role;
rollback;
