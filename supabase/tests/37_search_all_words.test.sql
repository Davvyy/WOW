-- 음식 검색: 띄어 쓴 여러 낱말이 이름(공백·기호 무시)에 모두 들어간 음식·상품을 맨 앞에(D68).
-- '키토 김밥' 이 일반 '김밥' 보다 '키토키친방탄정통김밥' 을 먼저 보여 준다. 한 낱말 검색은 그대로.
begin;
do $$
declare r record; first_code text; n int;
begin
  insert into food_db_cache (food_code, name_kr, category, serving_g, kcal, is_product, maker, unit_label) values
    ('P-T37-0001', '키토키친방탄정통김밥', '김밥', 210, 214.2, true, '(주)델리캡', '1회분(210g)'),
    ('P-T37-0002', '크레미 키토김밥 KIT', '김밥', 150, 460.5, true, '농업회사법인(주)담푸른', '1개(150g)'),
    ('P-T37-0003', '김밥', '김밥', 230, 486, true, 'DK홀딩스(미담)', '1개(230g)');

  select food_code into first_code from food_search('키토 김밥') limit 1;
  perform tests.ok(first_code in ('P-T37-0001', 'P-T37-0002'), '여러 낱말: 두 낱말이 모두 든 이름이 맨 앞');
  select count(*) into n from (select food_code from food_search('키토 김밥') limit 3) t
    where food_code in ('P-T37-0001', 'P-T37-0002');
  perform tests.eq(n, 2, '두 낱말이 모두 든 상품 두 개가 상위 3개 안');
  select count(*) into n from food_search('키토 김밥') where food_code = 'P-T37-0001';
  perform tests.eq(n, 1, '같은 상품은 한 번만');

  -- 순서 무관 · 기호 무시
  select food_code into first_code from food_search('김밥 키토키친') limit 1;
  perform tests.eq(first_code, 'P-T37-0001', '낱말 순서가 달라도 찾음');

  -- 한 낱말 검색은 전과 같은 경로(모든 낱말 일치 가지는 쓰지 않음)
  select count(*) into n from food_search('김밥') where food_code = 'P-T37-0003';
  perform tests.eq(n, 1, '한 낱말 검색은 그대로 찾음');

  -- 권한 유지
  perform tests.ok(has_function_privilege('authenticated', 'food_search(text)', 'execute'), 'authenticated 실행 가능');
  perform tests.ok(not has_function_privilege('anon', 'food_search(text)', 'execute'), 'anon 실행 불가');
end $$;
rollback;
