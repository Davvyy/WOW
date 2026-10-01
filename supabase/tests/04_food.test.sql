-- 식약처 DB 매핑(04 §4.2, T15): 동의어 → pg_trgm, ≥0.45 자동 / 0.25~0.45 후보 칩 / <0.25 미매칭
begin;
do $$
declare r jsonb;
begin
  perform tests.eq(map_food_candidates(array['설렁탕']) ->> 'food_code', 'D000060', 'T15 설렁탕 → 곰탕 코드(동의어)');
  perform tests.eq(map_food_candidates(array['공기밥', '쌀밥']) ->> 'match', 'auto', '동의어 자동 매칭');
  r := map_food_candidates(array['김치찌게']);
  perform tests.eq(r ->> 'match', 'chips', 'T15 유사도 0.25~0.45 → 후보 칩, 자동 매칭 없음');
  perform tests.ok(r ->> 'food_code' is null, '후보 칩 단계는 food_code 미지정');
  perform tests.eq(r #>> '{chips,0,name}', '김치찌개', '후보 칩 1순위 김치찌개');
  perform tests.eq(map_food_candidates(array['피자']) ->> 'match', 'none', '미매칭 → 확인 필요');
  perform tests.eq(map_food_candidates(array['정체불명', '흰쌀밥']) ->> 'food_code', 'D000001', '후보 3개 중 최고 유사도');
  perform tests.ok((select count(*) from food_search('김치')) >= 3, 'food_search 상위 결과');
end $$;
rollback;
