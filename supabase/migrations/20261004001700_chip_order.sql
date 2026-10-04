-- 포장 상품 후보 칩 순서(docs/02 §10 D66): 점검(게이트)에 밀린 상품을 후보 칩에서 밀리지 않은 상품 뒤로.
-- Edge 초안(_shared/analyze.ts)은 후보 칩이면 chips[0] 을 임시로 고른다(확인 필요). 가루에 밀린 '스타벅스 카페라테'(NESTLE, 100g 429 kcal)가
-- 첫 칩이면 '스타벅스 카페라떼' 초안 kcal 이 가루 값이 된다.
--  - 밀린 상품 = 제품 형태(form_bad: 마시는·먹는 질의의 가루·믹스·원료) · 핵심어가 꾸밈말로만(core_compound) ·
--    점수 0.45 미만(자동 점수가 아닌 약한 후보는 앞으로 올리지 않는다) ·
--    브랜드 불일치(아는 브랜드 질의에서 제조사가 별칭에 안 맞는데, 다른 후보 중 제조사가 맞고 형태·핵심어 점검도 통과한 상품이 있음).
--    브랜드가 맞는 상품이 모두 가루·꾸밈말뿐이면 다른 회사 상품을 브랜드로 밀지 않는다(스타벅스 → 가루뿐 → 다른 회사 마시는 카페라떼가 먼저).
--  - 칩 순서: 같은 묶음(애매함: 고른 상품 → 같은 이름 상품 → 나머지) 안에서 밀리지 않은 상품 → 밀린 상품, 각각 전과 같은 순서.
--    모두 밀렸으면 순서는 그대로. 애매할 때 앞의 두 묶음(고른 상품·같은 이름 상품)은 그대로 둔다.
--  - 마시는 질의(핵심어 = 브랜드를 뗀 마지막 낱말('…맛' 제외)이 라떼·커피·아메리카노·콜드브루·주스·에이드·스무디·우유·두유·요구르트·드링크·
--    콜라·사이다·탄산수·차·티·음료·워터로 끝남, 스파게티·떠먹는 요구르트 제외)면 같은 순서 칸(밀림·전 순서의 점수까지 같은 상품)에서
--    마시는 상품(단위 라벨 ml, 또는 분류가 …음료·주스·탄산수·액상차·액상커피)을 먼저('스타벅스 카페라떼' → 같은 이름 초콜릿과자보다 마시는 카페라떼).
--    자동이면 적용하지 않는다(첫 칩 = 고른 상품). 마시는 질의가 아니면 순서는 전과 같다.
--  - 자동 여부·고른 상품(best)·점수·애매함은 그대로(자동이면 고른 상품은 밀리지 않은 상품이라 첫 칩도 그대로).
--  - 후보 행에 unit_label 을 더 싣는다(마시는 상품 판단용).
--  - 나머지는 20261004001500 의 map_product_pick 그대로.

create or replace function map_product_pick(p_candidates text[]) returns jsonb
  language sql stable security definer set search_path = public, extensions set jit = off as $$
  with v as materialized (select * from product_name_variants(p_candidates)),
  -- 후보 행에 상품 칸을 함께 싣는다(다시 food_db_cache 와 조인하면 계획기가 전체 색인을 훑는다)
  hits as materialized (
    select f.food_code, f.name_kr, f.kcal, f.serving_g, f.name_norm, f.maker, f.category, v.ord, v.stripped, v.vn, 1::real as sim, f.unit_label
    from v join food_db_cache f on f.is_product and f.name_norm = v.vn
    union all
    select m.food_code, m.name_kr, m.kcal, m.serving_g, m.name_norm, m.maker, m.category, v.ord, v.stripped, v.vn, m.sim, m.unit_label from v, lateral (
      select f.food_code, f.name_kr, f.kcal, f.serving_g, f.name_norm, f.maker, f.category,
        case when cardinality(v.frags) = 0 then greatest(similarity(f.name_norm, v.vn), similarity(f.name_kr, v.raw))
          else similarity(f.name_norm, v.vn) end as sim, f.unit_label
      from food_db_cache f where f.is_product and f.name_norm % v.vn order by 8 desc, 1 limit 20) m
    union all
    select m.food_code, m.name_kr, m.kcal, m.serving_g, m.name_norm, m.maker, m.category, v.ord, v.stripped, v.vn, m.sim, m.unit_label from v, lateral (
      select f.food_code, f.name_kr, f.kcal, f.serving_g, f.name_norm, f.maker, f.category, similarity(f.name_norm, v.vn) as sim, f.unit_label
      from unnest(v.frags) fr join food_db_cache f on f.is_product
        and food_maker_key(f.maker) collate "C" >= fr collate "C" and food_maker_key(f.maker) collate "C" < (fr || chr(1114111)) collate "C"
        and strpos(f.name_norm, v.vn) > 0
      order by length(f.name_norm), 1 limit 20) m
    where v.stripped and length(v.vn) >= 2),
  r0 as (
    select h.food_code, h.name_kr, h.kcal, h.serving_g, h.name_norm, h.ord, h.stripped, h.vn, h.sim, c.core, c.powder_q, c.lastw,
      h.category, h.unit_label,
      cardinality(c.frags) > 0 as known,
      maker_match_pos(h.maker, c.frags || c.qwords) as maker_pos,
      h.name_norm ~ '오리지널|오리지날|original|클래식|classic|플레인|plain|바닐라' as plain,
      c.frags, c.qwords,
      not c.powder_q and (h.name_norm ~ '분말|파우더|믹스|생지|반죽|원료|베이스|농축액|시럽|조미료'
        or coalesce(h.category, '') ~ '분말|파우더|믹스|생지|반죽|원료|베이스|농축|시럽|조미료|인스턴트커피') as form_bad,
      coalesce(h.name_norm ~ (c.core || '[a-z0-9]*$'), false) as core_end, -- 끝의 영문·숫자 표기('…우유 C')는 건너뜀
      -- 핵심어가 이름 끝이 아니라 다른 음식 앞의 꾸밈말로만 있음('김치' → '김치덮밥', '햄' → '햄김치볶음밥'): 자동 확정하지 않는다
      coalesce(h.name_norm !~ (c.core || '[a-z0-9]*$')
        and h.name_norm ~ (c.core || '.*(밥|찌개|전골|국|탕|면|우동|만두|떡볶이|죽|피자|버거|샌드위치)[a-z0-9]*$'), false) as core_compound
    from hits h join (select distinct on (ord) * from v order by ord) c on c.ord = h.ord),
  r1 as (
    select *, case when brand_hit and length(vn) >= 2 and strpos(name_norm, vn) > 0
        and (stripped or length(lastw) >= 2 or exists (select 1 from regexp_split_to_table(name_kr, '\s+') t where food_name_norm(t) = lastw))
      then greatest(sim, 0.6 + 0.2 * length(vn) / length(name_norm)) else sim end::real as score
    from (select *, maker_pos is not null or (not stripped and known and name_norm = vn) as brand_hit from r0) x where not stripped or brand_hit),
  r2 as (select *, case when bool_or(brand_hit) over () and not brand_hit then 1 else 0 end as tier from r1),
  r3 as (select *, score >= max(score) over (partition by tier) - 0.1 as near,
    plain and score >= max(score) over (partition by tier) - 0.05 as plain_near from r2),
  r as materialized (
    select *, row_number() over (order by tier, near desc, form_bad, not core_end, plain_near desc, score desc, coalesce(maker_pos, 99),
      stripped, ord, food_code) as rk
    from r3),
  best as (select * from r order by rk limit 1),
  -- 고른 상품과 정규화 이름이 같은데 g당 kcal 이 30% 넘게 다른 상품(제조사마다 다른 '로제떡볶이' 등)
  alts as (
    select f.food_code, f.name_kr, f.kcal, b.score
    from best b join food_db_cache f on f.is_product and f.food_code <> b.food_code and f.name_norm = b.name_norm
    where b.score >= 0.45 and b.serving_g > 0 and f.serving_g > 0
      and greatest(f.kcal / f.serving_g, b.kcal / b.serving_g) > 1.3 * least(f.kcal / f.serving_g, b.kcal / b.serving_g)
      and abs(f.kcal / f.serving_g - b.kcal / b.serving_g) > 0.1 -- 0 kcal 근처 음료(0 vs 0.02 kcal/g)는 비율만 커서 뺀다
      and (not b.brand_hit or maker_match_pos(f.maker, b.frags || b.qwords) is not null)),
  amb as (select exists (select 1 from alts) as yes),
  -- 후보 이름 중 하나라도 아는 브랜드가 있으면, 고른 상품이 그 브랜드 일치일 때만 자동('롯데 자일리톨 껌' · '자일리톨' 처럼 브랜드 없는 후보로 우회하지 않게)
  auto as (select b.score >= 0.45 and not amb.yes and not b.form_bad and not b.core_compound
    and ((b.brand_hit and cardinality(b.frags) > 0) or not exists (select 1 from v where cardinality(v.frags) > 0)) as yes
    from best b, amb),
  -- 마시는 질의: 후보 이름의 핵심어(브랜드를 뗀 마지막 낱말, '…맛' 제외)가 음료 낱말로 끝남
  bev as (
    select coalesce(bool_or(cw ~ '(라떼|라테|커피|아메리카노|콜드브루|주스|쥬스|에이드|스무디|우유|두유|요구르트|야쿠르트|드링크|콜라|사이다|탄산수|탄산음료|차|티|음료|워터)$'
      and cw !~ '스파게티$' and v0 !~ '떠먹는'), false) as yes
    from (select food_name_norm(v.raw) as v0, food_name_norm((select w from regexp_split_to_table(v.raw, '\s+') with ordinality t(w, n)
        where w !~ '맛$' order by n desc limit 1)) as cw from v) q),
  -- 점검에 밀린 상품(칩 순서에만 쓴다): 제품 형태 · 핵심어가 꾸밈말로만 · 브랜드 불일치 · 약한 점수.
  --  브랜드 불일치 = 아는 브랜드 질의에서 제조사가 안 맞는데, 형태·핵심어 점검을 통과한 브랜드 일치 상품이 따로 있음(점수는 따지지 않음).
  --    브랜드 상품이 가루·꾸밈말뿐이면 다른 회사 상품을 브랜드로 밀지 않는다('스타벅스 카페라떼' → 가루뿐 → 다른 회사 카페라떼가 먼저).
  --  약한 점수 = 0.45 미만: 점검을 통과해도 앞으로 올리지 않는다('카누 아메리카노'(원두분말, 1)보다 '티오피 콜드브루'(0.32)가 먼저 오지 않게).
  rd as (
    select r.*, form_bad or core_compound or score < 0.45
      or (not brand_hit and exists (select 1 from r c where c.brand_hit and c.known and not c.form_bad and not c.core_compound)) as demoted
    from r),
  -- 같은 순서 칸(밀림, 고르는 순서의 점수까지 같은 상품: rk 에서 붙어 있는 묶음)과 그 칸의 첫 rk. 마시는 질의면 칸 안에서 마시는 상품 먼저
  rt as (
    select rd.*, min(rk) over (partition by demoted, tier, near, form_bad, core_end, plain_near, score) as tie_pos,
      bev.yes and not coalesce(auto.yes, false)
        and (coalesce(unit_label, '') ~* 'ml' or coalesce(category, '') ~ '음료|주스|탄산수|액상차|액상커피') as drink
    from rd cross join bev left join auto on true),
  -- 애매하면 고른 상품 → 같은 이름 상품들 → 나머지, 아니면 고르는 순서대로(첫 칩 = 고른 상품). 최대 10개
  -- 나머지 묶음 안에서는 밀리지 않은 상품 → 밀린 상품(각각 고르는 순서대로, 모두 밀렸으면 그대로). 마시는 질의면 같은 순서 칸 안에서 마시는 상품 먼저
  chips as (
    select * from (
      select distinct on (food_code) * from (
        select food_code, name_kr, kcal, score, 2 as grp, demoted, tie_pos, drink, rk from rt
        union all select food_code, name_kr, kcal, score, 1, false, 0::bigint, false, 0 from alts
        union all select b.food_code, b.name_kr, b.kcal, b.score, 0, false, 0::bigint, false, 0 from best b, amb where amb.yes
      ) u order by food_code, grp, rk) d
    order by grp, demoted, tie_pos, drink desc, rk, food_code limit 10)
  select jsonb_build_object(
    'match', case when coalesce(auto.yes, false) then 'auto' when b.score >= 0.25 then 'chips' else 'none' end,
    'food_code', case when auto.yes then b.food_code end,
    'kcal', case when auto.yes then b.kcal end,
    'score', b.score,
    'is_product', true,
    'ambiguous', amb.yes,
    'chips', (select coalesce(jsonb_agg(jsonb_build_object('food_code', z.food_code, 'name', z.name_kr, 'kcal', z.kcal, 'score', z.score,
      'is_product', true) order by z.grp, z.demoted, z.tie_pos, z.drink desc, z.rk, z.food_code), '[]') from chips z))
  from (select 1) one cross join amb left join best b on true left join auto on true
$$;

revoke execute on function map_product_pick(text[]) from public, anon, authenticated;
grant execute on function map_product_pick(text[]) to service_role;
