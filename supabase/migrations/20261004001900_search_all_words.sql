-- 음식 검색(P7 '항목 추가 — 검색'): 띄어 쓴 여러 낱말이 이름에 모두 들어간 음식·상품을 맨 앞에(D68).
-- 전에는 질의 전체를 한 문자열로 비교(유사도)해서 '키토 김밥' 이 일반 '김밥' 쪽에 가깝게 나오고
-- '키토키친방탄정통김밥' 처럼 두 낱말이 떨어져 든 상품은 상위 20 안에 들지 못했다.
-- 낱말은 공백으로 나누고, 이름과 같은 정규화(food_name_norm: 소문자·공백·기호 제거)로 비교해 순서·띄어쓰기와 무관하다.
-- 한 낱말 검색은 전과 같다(이 가지는 낱말이 둘 이상일 때만). AI 매칭(map_food_candidates)은 바꾸지 않는다.

-- 원래 정의(20261004001400_product_pieces.sql)에서 바꾼 것: 모든 낱말 일치 가지(점수 0.95)를 더하고, 같은 코드는 높은 점수 하나만.
create or replace function food_search(q text)
returns table (food_code text, name_kr text, kcal numeric, serving_g numeric, score real, is_product boolean, maker text, unit_label text,
  package_g numeric, pieces int)
  language sql stable security definer set search_path = public, extensions as $$
  with w as (
    select array_agg('%' || t || '%') as pats, count(*) as n
    from (select food_name_norm(s) as t from regexp_split_to_table(trim(coalesce(q, '')), '\s+') s) x
    where t <> ''
  ),
  words as (
    select f.food_code, f.name_kr, f.kcal, f.serving_g, 0.95::real as score, f.is_product,
      case when f.is_product then f.maker end as maker, case when f.is_product then f.unit_label end as unit_label
    from food_db_cache f, w
    where w.n >= 2 and f.name_norm like all (w.pats)
    order by f.is_product, char_length(f.name_kr), f.name_kr
    limit 20
  ),
  hits as (
    select * from words
    union all select * from food_match(q, false)
    union all select * from food_match(q, true)
  ),
  best as (
    select distinct on (h.food_code) h.* from hits h order by h.food_code, h.score desc
  ),
  top as (
    select * from best b order by b.score desc, b.is_product, b.name_kr, b.food_code limit 20
  )
  select x.*, f.package_g, case when f.package_g > 0 then u.pieces end
  from top x
  left join food_db_cache f on x.is_product and f.food_code = x.food_code
  left join user_product_pieces u on u.user_id = auth.uid() and u.food_code = x.food_code
  order by x.score desc, x.is_product, x.name_kr, x.food_code
$$;

revoke execute on function food_search(text) from public, anon;
grant execute on function food_search(text) to authenticated, service_role;
