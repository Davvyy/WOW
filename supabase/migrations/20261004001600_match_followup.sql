-- 포장 상품 매칭 후속(docs/02 §10 D66): 상품이 후보 칩이어도 '밀려난' 결과면 음식 자동 매칭보다 먼저 준다.
--  - 상품 결과가 후보 칩이고 최고 점수가 0.45 이상이면(약한 매칭이 아니라 브랜드·가루·핵심어·같은 이름 kcal 점검에 걸려 자동이 안 된 것)
--    음식 자동 매칭으로 넘기지 않고 상품 후보 칩을 그대로 준다('demoted': true). 포장 상품이라고 본 항목이 확인 없이
--    다른 음식 1인분('스타벅스 카페라떼' → 음식 카페라떼, '비비고 김치' → 김밥_김치)으로 확정되지 않게.
--  - 점수 0.45 미만인 약한 상품 후보 칩·미매칭은 전처럼 음식 매칭(자동이면 음식, 상품이 none 이면 음식 결과)으로 넘어간다.
--  - 나머지는 20261004001400 의 map_food_candidates 그대로(포장 아님 → 음식만, 상품 자동·애매함 → 상품).

create or replace function map_food_candidates(p_candidates text[], p_packaged boolean default false) returns jsonb
  language plpgsql stable security definer set search_path = public, extensions as $fn$
declare p jsonb; d jsonb;
begin
  if not coalesce(p_packaged, false) then return map_food_pick(p_candidates, false); end if;
  p := map_food_pick(p_candidates, true);
  if p ->> 'match' = 'auto' or coalesce((p ->> 'ambiguous')::boolean, false) then return p; end if;
  -- 점수는 충분한데 확인이 필요해 칩이 된 상품(밀려난 상품): 음식 자동 매칭보다 먼저
  if p ->> 'match' = 'chips' and coalesce((p ->> 'score')::numeric, 0) >= 0.45 then
    return p || jsonb_build_object('demoted', true);
  end if;
  d := map_food_pick(p_candidates, false);
  if d ->> 'match' = 'auto' or p ->> 'match' = 'none' then return d; end if;
  return p;
end $fn$;
revoke execute on function map_food_candidates(text[], boolean) from public, anon;
grant execute on function map_food_candidates(text[], boolean) to authenticated, service_role;
