-- 가공식품(상품) DB(docs/02 §10 D63): 식약처 「가공식품」 표준데이터(15100066)의 포장 상품을 food_db_cache 에 함께 넣는다.
-- meal_items.food_code 가 food_db_cache 를 참조하므로 같은 표에 두고 is_product 로 나눈다.
--  - 상품 행: food_code = 식약처 상품 코드(P…), serving_g·kcal·탄단지 = 1개(포장 전체·1회분·100g) 값, maker = 제조사,
--    unit_label = '1개(40g)' · '1회분(30g)' · '100g'. 적재는 supabase/seed/load_processed_food.mjs.
--  - 일반 음식 자동 매칭(map_food_candidates 기본)은 음식 행만 본다(D42 와 같은 이유: 일반 음식 매칭에 상품이 섞이지 않게).
--  - AI 가 포장 상품(packaged)이라고 한 항목은 상품 먼저(브랜드를 뗀 이름도), 없으면 음식으로 매칭한다. 임계값은 그대로.
--  - 검색(food_search)은 음식과 상품을 모두 돌려주고, 같은 점수면 음식이 먼저다.

alter table food_db_cache
  add column if not exists is_product boolean not null default false,
  add column if not exists maker text,
  add column if not exists unit_label text;

-- 상품 25만 건이 섞여도 음식 이름 매칭은 음식 행 부분 인덱스로 찾는다(상품은 기존 전체 인덱스)
create index if not exists food_db_cache_dish_name_trgm on food_db_cache using gin (name_kr gin_trgm_ops) where not is_product;

-- 한 종류(음식 또는 상품)의 이름 검색. 음식: 동의어 → pg_trgm 상위 10(전과 같음). 상품: pg_trgm 상위 20.
-- 상품의 이름 포함(ilike) 검색은 앱 검색(p_contains)에서만: 3글자 미만 낱말은 trgm 인덱스를 못 써 25만 행을 훑는다(약 0.2초).
-- 매칭은 유사도(%)만 쓴다 — 포함만 하는 이름은 유사도가 낮아 자동 매칭·후보 칩에 거의 들지 않는다.
create or replace function food_match(q text, p_product boolean, p_contains boolean default true)
returns table (food_code text, name_kr text, kcal numeric, serving_g numeric, score real, is_product boolean, maker text, unit_label text)
  language plpgsql stable security definer set search_path = public, extensions as $$
#variable_conflict use_column
begin
  if p_product and p_contains then
    return query
      select f.food_code, f.name_kr, f.kcal, f.serving_g, similarity(f.name_kr, q)::real, true, f.maker, f.unit_label
      from food_db_cache f
      where f.is_product and (f.name_kr % q or f.name_kr ilike '%' || q || '%')
      order by 5 desc, 2, 1 limit 20;
  elsif p_product then
    return query
      select f.food_code, f.name_kr, f.kcal, f.serving_g, similarity(f.name_kr, q)::real, true, f.maker, f.unit_label
      from food_db_cache f
      where f.is_product and f.name_kr % q
      order by 5 desc, 2, 1 limit 20;
  else
    return query
      select x.food_code, x.name_kr, x.kcal, x.serving_g, max(x.score)::real, false, null::text, null::text from (
        select f.food_code, f.name_kr, f.kcal, f.serving_g, similarity(f.name_kr, q) as score from food_db_cache f
        where not f.is_product and (f.name_kr % q or f.name_kr ilike '%' || q || '%')
        union all
        select f.food_code, f.name_kr, f.kcal, f.serving_g, similarity(s.alias, q) * s.weight from food_synonyms s
        join food_db_cache f on f.food_code = s.food_code where not f.is_product and (s.alias % q or s.alias = q)
      ) x
      group by 1, 2, 3, 4 order by 5 desc, 2 limit 10;
  end if;
end $$;

-- 음식 검색(05 API #14, P7 '항목 추가 — 검색'): 음식 + 상품, 점수 순(같으면 음식 먼저) 상위 20
drop function if exists food_search(text);
create function food_search(q text)
returns table (food_code text, name_kr text, kcal numeric, serving_g numeric, score real, is_product boolean, maker text, unit_label text)
  language sql stable security definer set search_path = public, extensions as $$
  select x.* from (select * from food_match(q, false) union all select * from food_match(q, true)) x
  order by x.score desc, x.is_product, x.name_kr, x.food_code limit 20
$$;

-- AI 후보 이름 → 찾을 이름. 상품이면 여러 단어 이름의 첫 단어를 브랜드 후보로 보고 뗀 이름(stripped)도 찾는다
-- ('롯데 칙촉' → '칙촉', 브랜드 '롯데'). 뗀 이름은 그 단어가 찾은 상품의 제조사에 들 때만 쓴다(map_food_pick).
create or replace function food_name_variants(p_candidates text[], p_product boolean)
returns table (name text, ord bigint, brand text, stripped boolean)
  language sql immutable set search_path = public, extensions as $$
  with c as (
    select btrim(n) as name, ord, case when p_product then (regexp_match(btrim(n), '^(\S+)\s+\S'))[1] end as brand
    from unnest(p_candidates) with ordinality u(n, ord) where btrim(coalesce(n, '')) <> ''
  )
  select name, ord, brand, false from c
  union all
  select regexp_replace(name, '^\S+\s+', ''), ord, brand, true from c where brand is not null
$$;

-- 04 §4.2 매핑(한 종류): 후보 3개 → 동의어 → trgm. ≥0.45 자동 / 0.25~0.45 후보 칩 / <0.25 미매칭.
-- 첫 단어를 뗀 이름은 그 단어가 제조사에 든 상품만('제로 콜라'가 일반 콜라로, '코카콜라 제로'가 다른 회사 '제로'로 가지 않게).
-- 같은 점수면 브랜드가 제조사 이름에 든 상품, 원래 이름, 후보 순서.
create or replace function map_food_pick(p_candidates text[], p_product boolean) returns jsonb
  language sql stable security definer set search_path = public, extensions as $$
  with r as materialized (
    select * from (
      select m.*, c.ord, c.stripped, coalesce(c.brand is not null and m.maker ilike '%' || c.brand || '%', false) as brand_hit
      from food_name_variants(p_candidates, p_product) c, lateral food_match(c.name, p_product, false) m) v
    where not v.stripped or v.brand_hit),
  best as (select * from r order by score desc, brand_hit desc, stripped, ord, food_code limit 1),
  chips as (select distinct on (food_code) * from r order by food_code, score desc)
  select jsonb_build_object(
    'match', case when b.score >= 0.45 then 'auto' when b.score >= 0.25 then 'chips' else 'none' end,
    'food_code', case when b.score >= 0.45 then b.food_code end,
    'kcal', case when b.score >= 0.45 then b.kcal end,
    'score', b.score,
    'is_product', p_product,
    'chips', (select coalesce(jsonb_agg(jsonb_build_object('food_code', z.food_code, 'name', z.name_kr, 'kcal', z.kcal, 'score', z.score,
      'is_product', z.is_product) order by z.score desc, z.food_code), '[]') from chips z))
  from (select 1) one left join best b on true
$$;

-- AI 항목 매핑(analyze-meal). 포장 상품(p_packaged)은 상품 먼저, 상품이 자동 매칭이 아니면 음식 자동 매칭 → 상품 후보 칩 → 음식 순.
-- 포장 상품이 아니면 음식만(전과 같음).
drop function if exists map_food_candidates(text[]);
create function map_food_candidates(p_candidates text[], p_packaged boolean default false) returns jsonb
  language plpgsql stable security definer set search_path = public, extensions as $$
declare p jsonb; d jsonb;
begin
  if not coalesce(p_packaged, false) then return map_food_pick(p_candidates, false); end if;
  p := map_food_pick(p_candidates, true);
  if p ->> 'match' = 'auto' then return p; end if;
  d := map_food_pick(p_candidates, false);
  if d ->> 'match' = 'auto' or p ->> 'match' = 'none' then return d; end if;
  return p;
end $$;

-- 최근 음식: 상품이면 제조사·단위 라벨도(앱 검색 시트가 같은 행 모양으로 보여 준다)
drop function if exists recent_foods(int);
create function recent_foods(p_limit int default 20)
returns table (name text, food_code text, kcal numeric, last_used timestamptz, is_product boolean, maker text, unit_label text)
  language sql stable as $$
  select name, food_code, kcal, last_used, is_product, maker, unit_label from (
    select distinct on (coalesce(i.food_code, i.chosen_name))
      i.chosen_name as name,
      i.food_code,
      r1(coalesce(f.kcal, i.serving_kcal,
        i.confirmed_kcal / nullif(i.portion_multiplier * i.count * case when i.broth_off then 0.6 else 1 end * coalesce(i.bite_fraction, 1), 0))) as kcal,
      coalesce(m.confirmed_at, m.captured_at) as last_used,
      coalesce(f.is_product, false) as is_product, f.maker, f.unit_label
    from meal_items i
    join meals m on m.id = i.meal_id
    left join food_db_cache f on f.food_code = i.food_code
    where m.status in ('confirmed', 'auto', 'corrected') and i.eaten and i.chosen_name is not null
      and coalesce(m.confirmed_at, m.captured_at) >= now() - interval '30 days'
      and m.participant_id in (select id from participants where user_id = auth.uid())
    order by coalesce(i.food_code, i.chosen_name), coalesce(m.confirmed_at, m.captured_at) desc
  ) x
  where kcal is not null and kcal > 0
  order by last_used desc
  limit greatest(1, least(coalesce(p_limit, 20), 50))
$$;

revoke execute on function food_match(text, boolean, boolean), food_name_variants(text[], boolean), map_food_pick(text[], boolean)
  from public, anon, authenticated;
grant execute on function food_match(text, boolean, boolean), food_name_variants(text[], boolean), map_food_pick(text[], boolean) to service_role;
revoke execute on function food_search(text), map_food_candidates(text[], boolean), recent_foods(int) from public, anon;
grant execute on function food_search(text), map_food_candidates(text[], boolean), recent_foods(int) to authenticated, service_role;
