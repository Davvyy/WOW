-- 조각 수 가드(D73).
-- AI 가 조각 음식(초밥·만두·김밥 조각 …)의 조각 수를 그릇·접시 수(count)로 낸 것으로 보인 음식 항목은 analyze-meal 이
-- count 1 · 인분(개수 × 배수 ÷ 10)으로 바꾸고 확인 필요로 둔다(조건: 포장 상품 아님, count ≥ 3, 항목 kcal > 1,500).
-- 그렇게 바꾼 초안 항목: meal_items.ai_piece_guard(기본 false). 앱 P7 이 그 항목 카드에 안내 배너를 띄운다.
-- 확정은 항목을 다시 쓰므로(confirm_meal 그대로) 확정 뒤에는 false.

alter table meal_items add column if not exists ai_piece_guard boolean not null default false;
