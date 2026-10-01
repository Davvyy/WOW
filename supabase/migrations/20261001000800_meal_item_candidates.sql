-- P7 후보 칩(이름·kcal 동시 변경)과 국물 토글을 앱이 그리려면 초안 항목에 후보별 1인분 kcal·국물 여부가 필요하다.
-- analyze-meal 이 채운다: candidates[0] = 선택된 이름, 나머지는 LLM 후보(04 §4.1 name_candidates).
alter table meal_items
  add column has_broth boolean not null default false,
  add column candidate_kcal numeric[] not null default '{}',
  add column candidate_food_codes text[] not null default '{}',
  add column serving_kcal numeric;
