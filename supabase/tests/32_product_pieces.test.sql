-- '몇 개입' 낱개 단위(D64): 포장 크기(package_g)를 아는 상품만, 사용자마다 개입 수를 기억하고 1개 kcal 을 계산한다
begin;
insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, is_product, maker, unit_label, package_g) values
  ('P900-000000000-0101', '칙촉', '비스킷/쿠키/크래커', 30, 150.3, true, '롯데제과(주)', '1회분(30g)', 180),
  ('P900-000000000-0102', '칙촉 말차', '비스킷/쿠키/크래커', 30, 148, true, '롯데제과(주)', '1회분(30g)', null),
  ('D900101', '초코칩쿠키', '과자류', 70, 308, false, null, null, null);

-- 1개 kcal = kcal ÷ serving_g × (package_g ÷ 개수), 소수 1자리. 칙촉 180g · 30g당 150.3 · 24개입 → 7.5g · 37.6 kcal
do $$
begin
  perform tests.eq(product_piece_kcal(150.3, 30, 180, 24), 37.6, '1개 kcal: 150.3 ÷ 30 × 7.5 = 37.6');
  perform tests.eq(r1(180::numeric / 24), 7.5, '1개 양: 180 ÷ 24 = 7.5');
  perform tests.eq(product_piece_kcal(150.3, 30, null, 24), null::numeric, '포장 크기를 모르면 계산하지 않음');
end $$;

-- ---------------- 지수: 저장·바꾸기·지우기·거절
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare r jsonb; c text := 'P900-000000000-0101';
begin
  r := set_product_pieces(c, 24);
  perform tests.eq((r ->> 'pieces')::int, 24, 'RPC: 24개입 저장');
  perform tests.eq((r ->> 'piece_g')::numeric, 7.5, 'RPC: 1개 7.5g');
  perform tests.eq((r ->> 'piece_kcal')::numeric, 37.6, 'RPC: 1개 37.6 kcal');
  perform tests.eq((select pieces from user_product_pieces where food_code = c), 24, '본인 행 24');
  r := set_product_pieces(c, 20);
  perform tests.eq((select count(*)::int from user_product_pieces), 1, 'RPC: 다시 저장하면 같은 행을 바꾼다(upsert)');
  perform tests.eq((select pieces from user_product_pieces where food_code = c), 20, 'RPC: 20개입으로 바뀜');
  r := set_product_pieces(c, null);
  perform tests.ok(r ->> 'pieces' is null, 'RPC: null 이면 지운 결과');
  perform tests.eq((select count(*)::int from user_product_pieces), 0, 'RPC: null 이면 행을 지운다');
  perform tests.throws(format('select set_product_pieces(%L, 12)', 'D900101'), 'PT422', 'RPC: 음식 코드 거절');
  perform tests.throws(format('select set_product_pieces(%L, 12)', 'P900-000000000-0102'), 'PT422', 'RPC: 포장 크기 없는 상품 거절');
  perform tests.throws(format('select set_product_pieces(%L, null)', 'D900101'), 'PT422', 'RPC: 음식 코드는 지우기도 거절');
  perform tests.throws(format('select set_product_pieces(%L, 12)', 'P-없는-코드'), 'PT422', 'RPC: 없는 코드 거절');
  perform tests.throws(format('select set_product_pieces(%L, 1)', c), 'PT422', 'RPC: 1개는 범위 밖');
  perform tests.throws(format('select set_product_pieces(%L, 201)', c), 'PT422', 'RPC: 201개는 범위 밖');
  perform set_product_pieces(c, 24);
  -- RLS: 남의 이름으로 쓰기 불가, 서비스 전용 조회 불가
  perform tests.throws(format('insert into user_product_pieces (user_id, food_code, pieces) values (%L, %L, 10)', tests.uid('밤산책'), c),
    '42501', 'RLS: 남의 행 쓰기 불가');
  perform tests.throws(format('select * from product_pieces_for(%L, array[%L])', tests.uid('지수'), c), '42501', '서비스 전용 조회는 참가자 호출 불가');
end $$;
reset role;

-- ---------------- 밤산책: 남의 행은 보이지 않고, 검색에는 내 개입 수만
select tests.login(tests.uid('밤산책'));
set local role authenticated;
do $$
declare s record; c text := 'P900-000000000-0101';
begin
  perform tests.eq((select count(*)::int from user_product_pieces), 0, 'RLS: 남의 행은 안 보임');
  update user_product_pieces set pieces = 3;
  delete from user_product_pieces;
  select * into s from food_search('칙촉') where food_code = c;
  perform tests.eq(s.package_g, 180::numeric, '검색: 포장 크기');
  perform tests.ok(s.pieces is null, '검색: 남이 넣은 개입 수는 안 나옴');
  perform set_product_pieces(c, 12);
  perform tests.eq((select pieces from food_search('칙촉') where food_code = c), 12, '검색: 내 개입 수 12');
  perform tests.eq((select count(*)::int from user_product_pieces), 1, 'RLS: 내 행 1개만');
end $$;
reset role;

-- ---------------- 지수: 내 행·검색은 그대로(밤산책의 수정·삭제가 닿지 않음), 음식 행은 개입 수 없음
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare s record; c text := 'P900-000000000-0101';
begin
  perform tests.eq((select count(*)::int from user_product_pieces), 1, 'RLS: 지수는 본인 행 1개만');
  perform tests.eq((select pieces from user_product_pieces), 24, 'RLS: 남이 바꾸거나 지우지 못함');
  select * into s from food_search('칙촉') where food_code = c;
  perform tests.eq(array[s.pieces, s.kcal, s.serving_g]::numeric[], array[24, 150.3, 30]::numeric[], '검색: 내 24개입 + 1회분 kcal·양(앱이 1개로 계산)');
  perform tests.eq(array[s.is_product::text, s.maker, s.unit_label], array['true', '롯데제과(주)', '1회분(30g)'], '검색: 다른 칸은 그대로');
  select * into s from food_search('칙촉 말차') where food_code = 'P900-000000000-0102';
  perform tests.ok(s.package_g is null and s.pieces is null, '검색: 포장 크기 없는 상품');
  select * into s from food_search('초코칩쿠키') where food_code = 'D900101';
  perform tests.ok(s.package_g is null and s.pieces is null and not s.is_product, '검색: 음식 행');
end $$;
reset role;

-- 익명은 호출 불가
set local role anon;
do $$ begin
  perform tests.throws(format('select set_product_pieces(%L, 24)', 'P900-000000000-0101'), '42501', '익명 호출 불가');
end $$;
reset role;

-- ---------------- 서비스(analyze-meal): 끼니 주인의 개입 수 → 1개 kcal
do $$
declare r record;
begin
  select * into r from product_pieces_for(tests.uid('지수'), array['P900-000000000-0101', 'P900-000000000-0102', 'D900101']);
  perform tests.eq(array[r.pieces, r.piece_g, r.piece_kcal]::numeric[], array[24, 7.5, 37.6]::numeric[], '서비스: 지수 24개입 → 7.5g · 37.6');
  perform tests.eq((select count(*)::int from product_pieces_for(tests.uid('지수'), array['P900-000000000-0101', 'D900101'])), 1, '서비스: 넣은 코드만');
  perform tests.eq((select piece_kcal from product_pieces_for(tests.uid('밤산책'), array['P900-000000000-0101'])), 75.2, '서비스: 밤산책 12개입 → 75.2');
  perform tests.eq((select count(*)::int from product_pieces_for(tests.uid('강남콩'), array['P900-000000000-0101'])), 0, '서비스: 넣지 않은 사용자는 없음');
end $$;

-- ---------------- 확정: 서버 변경 없이 앱이 보낸 1개 kcal(serving_kcal)과 먹은 개수(portion_multiplier)를 그대로 저장
do $$
declare uid uuid := tests.uid('지수'); r jsonb; ph uuid; m uuid;
begin
  r := create_photo(uid, repeat('f2', 32), 400000, 1568, 1176, '2026-10-14 15:30+09', '2026-10-14 15:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('f2', 32), 400000, 1568, 1176, '2026-10-14 15:30+09');
  r := create_meal(uid, ph, false, '2026-10-14 15:30+09', p_slot => 'snack'); m := (r ->> 'meal_id')::uuid;
  update meals set status = 'draft', ai_kcal = 75.2 where id = m;
  r := confirm_meal(uid, m, '[{"chosen_name":"칙촉","food_code":"P900-000000000-0101","serving_kcal":37.6,"candidate_kcal":[37.6],
    "name_candidates":["칙촉"],"count":1,"portion_multiplier":2.0,"eaten":true,"input_type":"ai"}]'::jsonb,
    (select version from meals where id = m), '2026-10-14 15:35+09');
  perform tests.eq((r ->> 'confirmed_kcal')::numeric, 75.2, '확정: 37.6 × 2개 = 75.2');
  perform tests.eq((select array[serving_kcal, portion_multiplier, confirmed_kcal] from meal_items where meal_id = m),
    array[37.6, 2.0, 75.2]::numeric[], '확정: 1개 kcal·개수·항목 kcal 저장');
end $$;

-- 최근 음식도 검색과 같은 칸(포장 크기·1회분 양·내 개입 수)
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare s record;
begin
  select * into s from recent_foods(50) where food_code = 'P900-000000000-0101';
  perform tests.eq(array[s.kcal, s.serving_g, s.package_g, s.pieces]::numeric[], array[150.3, 30, 180, 24]::numeric[], '최근 음식: 1회분 kcal·양·포장·개입 수');
end $$;
reset role;

-- ---------------- 상품 매칭: 띄어쓰기만 다른 같은 이름이 부분 유사도보다 먼저(브랜드를 뗀 이름은 제조사에 그 브랜드가 있을 때만)
insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, is_product, maker, unit_label, package_g) values
  ('P900-000000000-0201', '홈런볼초코', '비스킷/쿠키/크래커', 46, 174, true, '해태제과식품(주)', '1개(46g)', 46),
  ('P900-000000000-0202', '홈런볼 초코&딸기 2MIX', '비스킷/쿠키/크래커', 30, 160, true, '해태제과식품(주)', '1회분(30g)', 300);
do $$
declare r jsonb;
begin
  r := map_food_candidates(array['홈런볼 초코'], true);
  perform tests.eq(r ->> 'food_code', 'P900-000000000-0201', '상품 매칭: 홈런볼 초코 → 홈런볼초코(띄어쓰기 무시 같은 이름)');
  perform tests.eq((r ->> 'kcal')::numeric, 174::numeric, '상품 매칭: 홈런볼초코 174 kcal');
  perform tests.eq(r ->> 'match', 'auto', '상품 매칭: 같은 이름은 자동');
  r := map_food_candidates(array['해태 홈런볼 초코'], true);
  perform tests.eq(r ->> 'food_code', 'P900-000000000-0201', '상품 매칭: 해태 홈런볼 초코 → 브랜드 뗀 이름이 홈런볼초코(제조사 해태)');
  r := map_food_candidates(array['홈런볼 초코&딸기 2MIX'], true);
  perform tests.eq(r ->> 'food_code', 'P900-000000000-0202', '상품 매칭: 2MIX 는 그대로');
  r := map_food_candidates(array['오리온 홈런볼 초코'], true);
  perform tests.ok(not exists (select 1 from jsonb_array_elements(r -> 'chips') e where (e ->> 'score')::numeric = 1),
    '상품 매칭: 제조사에 없는 브랜드를 뗀 이름은 같은 이름으로 치지 않음');
end $$;
rollback;
