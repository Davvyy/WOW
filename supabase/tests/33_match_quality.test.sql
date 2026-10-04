-- 포장 상품 이름 매칭 품질(D65): 브랜드 → 제조사 별칭, 정규화 이름, 제품 형태, 핵심어, 음식 매칭은 그대로
begin;
insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, is_product, maker, unit_label) values
  -- 브랜드 별칭: 백설(CJ) → 씨제이, 다른 회사의 같은 이름 '비엔나'보다 먼저
  ('P933-000000000-0101', '비엔나', '소시지', 30, 31, true, 'MEICA GMBH & CO KG', '1회분(30g)'),
  ('P933-000000000-0102', '그릴비엔나', '소시지', 30, 73.5, true, '씨제이제일제당(주)진천 BLOSSOM CAMPUS', '1회분(30g)'),
  -- 둘째 낱말 브랜드(맥심 → 동서식품) + 기호 정규화(티.오.피)
  ('P933-000000000-0201', '맥심 티.오.피 스위트 아메리카노', '액상커피', 275, 60, true, '동서식품(주)', '1개(275ml)'),
  ('P933-000000000-0202', '티오피 커피', '액상커피', 200, 50, true, '농업회사법인(주)동서웰빙', '1개(200ml)'),
  -- 표기 정규화: '2%' → '이프로'
  ('P933-000000000-0301', '이프로부족할때 복숭아', '액상음료', 240, 64.8, true, '롯데칠성음료(주)', '1개(240ml)'),
  -- 브랜드 제조사 상품이 없으면: 브랜드를 뗀 이름은 쓰지 않고(I1), 원래 이름이 비슷한 다른 회사 상품은 확인 필요(후보 칩)
  ('P933-000000000-0401', '자일리톨 블랙', '껌', 10, 24.2, true, '(주)윌리엄자일리톨', '1회분(10g)'),
  ('P933-000000000-0402', '자일리톨 알파', '껌', 10, 25, true, '(주)윌리엄자일리톨', '1회분(10g)'),
  -- 첫 낱말을 뗀 이름은 그 낱말이 제조사에 맞을 때만, 남는 낱말('제로')은 브랜드가 아님(I1)
  ('P933-000000000-0501', '칠성 사이다', '탄산음료', 250, 105, true, '롯데칠성음료(주)', '1개(250ml)'),
  ('P933-000000000-0502', '제로', '기타 빵', 55, 220, true, '제로베이커리', '1개(55g)'),
  -- 제품 형태: 같은 브랜드·비슷한 점수면 가루(믹스·인스턴트커피)보다 마시는 제품
  ('P933-000000000-0601', '맥심 카페라떼 믹스', '인스턴트커피', 100, 417, true, '동서식품㈜', '100g'),
  ('P933-000000000-0602', '맥심 카페라떼 컵음료', '액상커피', 200, 120, true, '동서식품㈜', '1개(200ml)'),
  -- 핵심어: '부라보콘' → '…콘'으로 끝나는 상품, '주부9단 햄' → '…햄'으로 끝나는 상품(다른 회사의 햄김치볶음밥은 브랜드로 밀림)
  ('P933-000000000-0701', '부라보체리', '아이스크림', 140, 245, true, '해태아이스크림(주)', '1개(140ml)'),
  ('P933-000000000-0702', '부라보소프트콘', '아이스크림', 140, 225.4, true, '해태아이스크림(주)', '1개(140ml)'),
  ('P933-000000000-0711', '주부9단로스구이', '햄', 30, 70, true, '(주)농협목우촌', '1회분(30g)'),
  ('P933-000000000-0712', '주부9단살코기햄', '햄', 30, 60, true, '(주)농협목우촌', '1회분(30g)'),
  ('P933-000000000-0713', '목우촌 주부9단 햄김치볶음밥', '밥류', 210, 378, true, '농업회사법인 주식회사 한우물', '1개(210g)'),
  -- 브랜드를 뗀 이름이 긴 상품 이름에 들면(남양 17차 → 몸이맑아지는시간17차) 자동
  ('P933-000000000-0801', '몸이맑아지는시간 17차', '액상차', 340, 0, true, '남양유업(주)', '1개(340ml)'),
  -- 위탁 제조(OEM): 브랜드를 붙인 이름이 통째로 같은 상품은 제조사가 별칭에 없어도 브랜드 상품(별칭 제조사의 다른 상품보다 먼저)
  ('P933-000000000-0901', '스타벅스 다크초콜릿', '초콜릿', 15, 76.5, true, 'STEENLAND CHOCOLATE B.V.', '1회분(15g)'),
  ('P933-000000000-0902', '페루지나 다크초콜릿 70', '초콜릿', 15, 80, true, 'NESTLE ITALIANA SPA', '1회분(15g)'),
  -- 브랜드를 붙인 이름 안에서 마지막 낱말이 더 긴 낱말의 일부일 뿐이면('김' ⊂ '김치참치') 이름 포함 점수를 주지 않는다
  ('P933-000000000-1001', '동원 김치참치', '참치', 100, 180, true, '(주)동원F&B', '1회분(100g)'),
  -- 자동 확정 막기: 가루만 있는 마시는 질의, 핵심어가 다른 음식의 꾸밈말일 뿐인 상품('김치' → '김치덮밥')
  ('P933-000000000-1103', '맥심 모카라떼 믹스', '인스턴트커피', 100, 420, true, '동서식품㈜', '100g'),
  ('P933-000000000-1101', '스타벅스 카페라테', '인스턴트커피', 100, 429, true, 'NESTLE UK LTD', '100g'),
  ('P933-000000000-1102', '습 김치덮밥', '즉석밥', 252, 340.2, true, '씨제이제일제당주식회사', '1개(252g)'),
  -- 브랜드를 붙인 이름의 포함 점수: 마지막 낱말이 2글자 이상이면 붙여 쓴 이름에서도('펩시 제로' → '펩시제로슈거', 같은 회사 '밀키스제로'보다 먼저)
  ('P933-000000000-1201', '펩시제로슈거', '탄산음료', 355, 0, true, '롯데칠성음료(주)', '1개(355ml)'),
  ('P933-000000000-1202', '밀키스제로', '탄산음료', 300, 9, true, '롯데칠성음료(주)', '1개(300ml)'),
  ('D933001', '그릴비엔나', '구이류', 100, 300, false, null, null);

do $$
declare r jsonb;
begin
  -- ---------------- 정규화
  perform tests.eq(food_name_norm('２％ 부족할 때'), '2부족할때', '정규화: 전각 → 반각, 공백·% 제거');
  perform tests.eq(food_name_norm('Maxim 에스프레소 T.O.P [블랙]-1_2/3,4'), 'maxim에스프레소top블랙1234', '정규화: 소문자, 기호 제거');
  perform tests.eq((select name_norm from food_db_cache where food_code = 'P933-000000000-0201'), '맥심티오피스위트아메리카노', '정규화: 생성 열 name_norm');
  perform tests.eq(food_maker_key('농업회사법인(주)동서웰빙'), '동서웰빙', '정규화: 제조사 앞 법인 표기 제거');
  perform tests.eq(maker_match_pos('동서식품㈜', array['동서식품']), 1, '제조사: 동서식품㈜ = 동서식품');
  perform tests.ok(maker_match_pos('농업회사법인(주)동서웰빙', array['동서식품']) is null, '제조사: 동서웰빙 ≠ 동서식품');
  perform tests.ok(maker_match_pos('현대상회', array['대상']) is null, '제조사: 2글자 조각은 앞글자만(현대상회 ≠ 대상)');
  perform tests.eq(maker_match_pos('THE HERSHEY COMPANY', array['허쉬', 'hershey']), 2, '제조사: 3글자 이상 조각은 이름 안에서도');

  r := map_food_candidates(array['롯데 2%부족할때'], true);
  perform tests.eq(r ->> 'food_code', 'P933-000000000-0301', '정규화: 2%부족할때 → 이프로부족할때 복숭아');
  perform tests.eq(r ->> 'match', 'auto', '정규화: 브랜드 제조사 상품 이름에 들면 자동');

  -- ---------------- 브랜드 → 제조사
  r := map_food_candidates(array['CJ 백설 비엔나'], true);
  perform tests.eq(r ->> 'food_code', 'P933-000000000-0102', '브랜드: CJ 백설 비엔나 → 씨제이 그릴비엔나(다른 회사의 같은 이름 비엔나보다 먼저)');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P933-000000000-0102', '브랜드: 첫 후보 칩 = 고른 상품');
  r := map_food_candidates(array['동서 맥심 티오피'], true);
  perform tests.eq(r ->> 'food_code', 'P933-000000000-0201', '브랜드: 맥심(둘째 낱말) → 동서식품, 티.오.피 정규화');
  perform tests.ok(not exists (select 1 from jsonb_array_elements(r -> 'chips') e where e ->> 'food_code' = 'P933-000000000-0202' and (e ->> 'score')::numeric >= 0.45),
    '브랜드: 동서웰빙의 티오피 커피는 브랜드 상품이 아님');
  r := map_food_candidates(array['롯데 자일리톨 껌'], true);
  perform tests.ok(r ->> 'food_code' is null and not exists (select 1 from jsonb_array_elements(r -> 'chips') e where e ->> 'food_code' like 'P933%'),
    '브랜드: 롯데 자일리톨 껌 → 다른 회사의 자일리톨 블랙으로 가지 않음');
  r := map_food_candidates(array['롯데 자일리톨 알파'], true);
  perform tests.eq(r ->> 'match', 'chips', '브랜드: 브랜드 제조사 상품이 없으면 다른 회사 상품은 후보 칩(자동 아님)');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P933-000000000-0402', '브랜드: 다른 회사 상품만 있으면 그중에서');
  r := map_food_candidates(array['칠성사이다 제로'], true);
  perform tests.ok(coalesce(r ->> 'food_code', '') <> 'P933-000000000-0502'
    and not exists (select 1 from jsonb_array_elements(r -> 'chips') e where e ->> 'food_code' = 'P933-000000000-0502'),
    '브랜드: 뗀 이름에 남는 낱말(제로)은 브랜드가 아님(제로베이커리 제외)');
  r := map_food_candidates(array['스타벅스 다크초콜릿'], true);
  perform tests.eq(r ->> 'food_code', 'P933-000000000-0901', '브랜드: 브랜드까지 같은 이름(위탁 제조)이 별칭 제조사의 다른 상품보다 먼저');
  perform tests.eq(r ->> 'match', 'auto', '브랜드: 브랜드까지 같은 이름은 자동');
  r := map_food_candidates(array['롯데 자일리톨 껌', '자일리톨 껌', '자일리톨'], true);
  perform tests.ok(r ->> 'match' <> 'auto', '브랜드: 후보 중 하나라도 아는 브랜드면 다른 후보의 다른 회사 상품도 자동이 아님');
  r := map_food_candidates(array['동원 김'], true);
  perform tests.ok(not (r ->> 'match' = 'auto' and r ->> 'food_code' = 'P933-000000000-1001'), '포함 점수: 동원 김 → 동원 김치참치 자동 아님');
  r := map_food_candidates(array['스타벅스 카페라떼', '카페라떼'], true);
  perform tests.ok(not (r ->> 'match' = 'auto' and r ->> 'food_code' = 'P933-000000000-1101'), '형태: 마시는 질의에 가루 상품을 자동으로 고르지 않음');
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P933-000000000-0602', '형태: 같은 브랜드(동서식품)의 마시는 카페라떼가 먼저');
  r := map_food_candidates(array['맥심 모카라떼', '모카라떼'], true);
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P933-000000000-1103', '형태: 가루 상품만 있으면 그 상품');
  perform tests.ok(r ->> 'match' <> 'auto', '형태: 마시는 질의에 가루 상품뿐이면 자동 아님(후보 칩)');
  r := map_food_candidates(array['비비고 김치', '김치'], true);
  perform tests.ok(r ->> 'match' <> 'auto', '핵심어: 김치 → 김치덮밥(다른 음식의 꾸밈말)은 자동 아님');
  r := map_food_candidates(array['펩시 제로', '제로'], true);
  perform tests.eq(r ->> 'food_code', 'P933-000000000-1201', '포함 점수: 펩시 제로 → 펩시제로슈거(밀키스제로 아님)');
  r := map_food_candidates(array['남양 17차'], true);
  perform tests.eq(r ->> 'food_code', 'P933-000000000-0801', '브랜드: 뗀 이름이 상품 이름에 들면(17차) 자동');

  -- ---------------- 제품 형태
  r := map_food_candidates(array['맥심 카페라떼'], true);
  perform tests.eq(r ->> 'food_code', 'P933-000000000-0602', '형태: 가루(믹스·인스턴트커피)보다 마시는 제품');
  r := map_food_candidates(array['맥심 카페라떼 믹스'], true);
  perform tests.eq(r ->> 'food_code', 'P933-000000000-0601', '형태: 질의가 믹스면 믹스 제품');

  -- ---------------- 핵심어
  r := map_food_candidates(array['해태 부라보콘'], true);
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P933-000000000-0702', '핵심어: 부라보콘 → …콘(부라보체리보다 먼저)');
  r := map_food_candidates(array['목우촌 주부9단 햄'], true);
  perform tests.eq(r -> 'chips' -> 0 ->> 'food_code', 'P933-000000000-0712', '핵심어: 주부9단 햄 → 주부9단살코기햄');
  perform tests.ok(not exists (select 1 from jsonb_array_elements(r -> 'chips') with ordinality x(e, o) where o <= 2 and e ->> 'food_code' = 'P933-000000000-0713'),
    '핵심어: 다른 회사의 햄김치볶음밥은 앞에 오지 않음');

  -- ---------------- 음식 매칭은 그대로(상품이 섞이지 않음)
  r := map_food_candidates(array['CJ 백설 비엔나', '그릴비엔나'], false);
  perform tests.eq(r ->> 'food_code', 'D933001', '음식 매칭: 같은 이름 음식 행');
  perform tests.eq((r ->> 'is_product')::boolean, false, '음식 매칭: is_product = false');
  perform tests.ok(not exists (select 1 from jsonb_array_elements(r -> 'chips') e where e ->> 'food_code' like 'P%'), '음식 매칭: 칩에 상품 없음');
  perform tests.eq((map_food_candidates(array['맥심 티오피']) ->> 'match'), 'none', '음식 매칭: 상품 이름만 있으면 미매칭');
end $$;

-- 참가자는 별칭 표를 읽지 못한다
set local role authenticated;
do $$ begin
  perform tests.throws('select * from brand_makers', '42501', '별칭 표는 참가자가 읽을 수 없음');
  perform tests.throws($q$select map_product_pick(array['롯데 칙촉'])$q$, '42501', '상품 매칭 내부 함수는 참가자 호출 불가');
end $$;
reset role;
rollback;
