-- 조각 수 가드(D73).
-- AI 가 조각 음식(초밥·만두·김밥 조각 …)의 조각 수를 그릇·접시 수(count)로 낸 것으로 보인 음식 항목은 analyze-meal 이
-- count 1 · 인분(개수 × 배수 ÷ 10)으로 바꾸고 확인 필요로 둔다(조건: 포장 상품 아님, count ≥ 3, 항목 kcal > 1,500).
-- 그렇게 바꾼 초안 항목: meal_items.ai_piece_guard(기본 false). 앱 P7 이 그 항목 카드에 안내 배너를 띄운다.
-- 확정은 항목을 다시 쓰므로(confirm_meal 그대로) 확정 뒤에는 false.

alter table meal_items add column if not exists ai_piece_guard boolean not null default false;

-- 가드는 1인분이 한 접시 크기(≥ 200 g)이거나 이름·분류가 조각 음식(초밥·만두·떡 …)일 때만 건다(찐빵·달걀 같은 1개 단위 음식 제외).
-- 그래서 음식 매칭(map_food_candidates(…, false) → map_dish_pick)이 1인분 g(serving_g)·분류(category)도 준다:
-- 자동 매칭이면 최상위에, 후보 칩마다에도. 나머지는 20261004001500 의 map_dish_pick 그대로(상품 매칭은 바뀌지 않음).
create or replace function map_dish_pick(p_candidates text[]) returns jsonb
  language sql stable security definer set search_path = public, extensions set jit = off as $$
  with r as materialized (
    select * from (
      select m.*, c.ord, c.stripped, coalesce(c.brand is not null and m.maker ilike '%' || c.brand || '%', false) as brand_hit
      from food_name_variants(p_candidates, false) c, lateral food_match(c.name, false, false) m) v
    where not v.stripped or v.brand_hit),
  best as (select * from r order by score desc, brand_hit desc, stripped, ord, food_code limit 1),
  chips as (select distinct on (food_code) * from r order by food_code, score desc)
  select jsonb_build_object(
    'match', case when b.score >= 0.45 then 'auto' when b.score >= 0.25 then 'chips' else 'none' end,
    'food_code', case when b.score >= 0.45 then b.food_code end,
    'kcal', case when b.score >= 0.45 then b.kcal end,
    'serving_g', case when b.score >= 0.45 then b.serving_g end,
    'category', case when b.score >= 0.45 then (select f.category from food_db_cache f where f.food_code = b.food_code) end,
    'score', b.score,
    'is_product', false,
    'ambiguous', false,
    'chips', (select coalesce(jsonb_agg(jsonb_build_object('food_code', z.food_code, 'name', z.name_kr, 'kcal', z.kcal, 'score', z.score,
      'is_product', z.is_product, 'serving_g', z.serving_g, 'category', f.category) order by z.score desc, z.food_code), '[]')
      from chips z left join food_db_cache f on f.food_code = z.food_code))
  from (select 1) one left join best b on true
$$;
revoke execute on function map_dish_pick(text[]) from public, anon, authenticated;
grant execute on function map_dish_pick(text[]) to service_role;
