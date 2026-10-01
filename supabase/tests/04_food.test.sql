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

-- 최근 음식(30일, 본인 확정 끼니)
begin;
do $$
declare uid uuid := tests.uid('지수'); m meals;
begin
  -- 지수 오늘 점심을 항목과 함께 다시 확정(김 제외)
  select * into m from meals where participant_id = tests.pid('지수') and local_date = '2026-10-13' and slot = 'lunch';
  perform confirm_meal(uid, m.id, jsonb_build_array(
    jsonb_build_object('chosen_name', '흰쌀밥', 'food_code', 'D000001', 'portion_multiplier', 1.5),
    jsonb_build_object('chosen_name', '김치찌개', 'food_code', 'D000010', 'broth_off', true),
    jsonb_build_object('chosen_name', '엄마표 김밥', 'serving_kcal', 350, 'input_type', 'manual'),
    jsonb_build_object('chosen_name', '김', 'food_code', 'D000050', 'eaten', false)), m.version);
end $$;
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$ begin
  perform tests.eq((select kcal from recent_foods() where name = '흰쌀밥'), 310.0, '최근 음식: 곱빼기로 먹어도 1인분 kcal(식약처 값)');
  perform tests.eq((select kcal from recent_foods() where name = '엄마표 김밥'), 350.0, '최근 음식: 직접 입력은 확정값에서 1인분 환산');
  perform tests.ok(not exists (select 1 from recent_foods() where name = '김'), '최근 음식: 먹지 않은 항목 제외');
  perform tests.ok((select count(*) from recent_foods(2)) = 2, '최근 음식: 개수 제한');
  perform tests.ok((select count(*) from food_search('찌개')) >= 3, '검색: 참가자 RPC 사용 가능');
end $$;
reset role;
select tests.login(tests.uid('밤산책'));
set local role authenticated;
do $$ begin
  perform tests.ok(not exists (select 1 from recent_foods() where name = '엄마표 김밥'), '최근 음식: 남의 끼니는 안 보임');
end $$;
reset role;
rollback;
