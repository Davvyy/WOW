-- 포장 상품 이름 매칭 품질(docs/02 §10 D65): 브랜드 → 제조사 별칭, 정규화 이름, 제품 형태·핵심어 우선, 223개 점검(supabase/seed/match_audit.mjs).
-- 상품 매칭(map_food_candidates(…, true) → map_food_pick(…, true))만 바뀐다. 음식 매칭·검색(food_search·food_match)은 그대로.
--  - name_norm: NFKC(전각 → 반각) · 소문자 · 공백과 기호(% · & ( ) [ ] - _ / . , 등)를 뺀 이름. 생성 열이라 다시 적재할 필요가 없다.
--    '롯데 2%부족할때' · '맥심 티.오.피' · 'T.O.P' 처럼 띄어쓰기·기호만 다른 이름을 같은 이름으로 본다.
--  - brand_makers: 브랜드(질의 낱말) → 제조사 이름 조각. 질의의 어느 자리든 아는 브랜드 낱말이 있거나 첫 낱말이 제조사에 맞으면 브랜드 일치.
--  - name_spellings: 질의 표기 → 데이터 표기('2%' → '이프로', 데이터의 '이프로부족할때').

-- ---------------------------------------------------------------- 정규화
-- NFKC 로 전각·호환 문자(２％ · ㈜ · ㎖)를 펴고 소문자로, 공백과 기호를 뺀다. 한글·영문·숫자만 남는다.
-- 문자 클래스([:alnum:])는 DB 로캘에 따라 한글을 못 알아볼 수 있어 뺄 기호를 직접 적는다.
-- 아래 세 함수는 매칭 한 번에 수백 번 불려 인라인되도록 set search_path 를 두지 않는다(pg_catalog 함수만 쓰고 public 은 스키마를 붙여 부른다).
create or replace function food_name_norm(t text) returns text
  language sql immutable parallel safe as $$
  select pg_catalog.regexp_replace(pg_catalog.lower(normalize(coalesce(t, ''), NFKC)),
    '[][\s%·&()_/.,''"+!?~:;*<>{}#@`|=^$…・’‘“”®™-]+', '', 'g')
$$;

-- 제조사 앞머리의 법인 표기('(주)' · '주식회사' · '농업회사법인' …)를 뗀 정규화 이름: 브랜드 상품을 제조사 앞글자로 찾는 색인용
create or replace function food_maker_key(t text) returns text
  language sql immutable parallel safe as $$
  select pg_catalog.regexp_replace(public.food_name_norm(t), '^(주식회사|유한회사|농업회사법인|영농조합법인|재단법인|사단법인|주|유)+', '')
$$;

-- 제조사가 맞는 첫 브랜드 조각(정규화)의 순번, 없으면 null: 법인 표기를 뗀 제조사가 조각으로 시작하거나, 3글자 이상 조각이 제조사 이름에 든다.
-- 2글자 조각은 앞글자만 본다('대상'이 '현대상회'에, '롯데'가 '크리스피크림롯데…점'에 맞지 않게).
create or replace function maker_match_pos(p_maker text, p_frags text[]) returns int
  language sql immutable parallel safe as $$
  select pg_catalog.min(u.n)::int
  from (select public.food_maker_key(p_maker) as k, public.food_name_norm(p_maker) as nn) m,
    pg_catalog.unnest(p_frags) with ordinality u(x, n)
  where p_maker is not null and u.x <> ''
    and (pg_catalog.starts_with(m.k, u.x) or (pg_catalog.length(u.x) >= 3 and pg_catalog.strpos(m.nn, u.x) > 0))
$$;

-- 생성 열을 더하면 표 전체를 다시 쓰고(그동안 매칭·검색이 기다린다) 모든 색인을 다시 만든다:
-- 잠금을 오래 기다리지 않고, 더는 쓰지 않는 공백 뺀 이름 색인(20261004001400, name_norm 이 대신)을 먼저 지워 다시 만들지 않게 한다.
set lock_timeout = '5s';
set statement_timeout = '10min';
drop index if exists food_db_cache_product_nospace;
alter table food_db_cache add column if not exists name_norm text generated always as (food_name_norm(name_kr)) stored;

-- 상품: 정규화 이름 같음(= 은 해시 색인이 btree 보다 빨리 만들어지고 작다)·trgm 유사도(%)·브랜드 제조사 앞글자
create index if not exists food_db_cache_product_norm on food_db_cache using hash (name_norm) where is_product;
create index if not exists food_db_cache_product_norm_trgm on food_db_cache using gin (name_norm gin_trgm_ops) where is_product;
create index if not exists food_db_cache_product_maker on food_db_cache ((food_maker_key(maker)) collate "C") where is_product;

-- ---------------------------------------------------------------- 브랜드 → 제조사
create table if not exists brand_makers (
  brand text primary key,   -- 질의 낱말(대소문자·기호 무시)
  makers text[] not null    -- 제조사 이름 조각(대소문자·공백·기호 무시). 첫 조각부터 제조사 앞글자 검색에도 쓴다
);
alter table brand_makers enable row level security;
revoke all on brand_makers from anon, authenticated;
grant all on brand_makers to service_role;

insert into brand_makers (brand, makers) values
  ('삼립', '{삼립,샤니,호남샤니,SPC,에스피씨}'), ('샤니', '{삼립,샤니,호남샤니,SPC,에스피씨}'), ('SPC', '{삼립,샤니,호남샤니,SPC,에스피씨}'),
  ('CJ', '{씨제이,CJ}'), ('씨제이', '{씨제이,CJ}'), ('비비고', '{씨제이,CJ}'), ('백설', '{씨제이,CJ}'), ('햇반', '{씨제이,CJ}'),
  ('스팸', '{씨제이,CJ}'), ('고메', '{씨제이,CJ}'),
  ('정관장', '{한국인삼공사}'),
  ('동서', '{동서식품}'), ('맥심', '{동서식품}'), ('포스트', '{동서식품}'),
  ('롯데', '{롯데}'), ('칠성', '{롯데}'), ('펩시', '{롯데,PEPSI}'),
  ('오뚜기', '{오뚜기}'), ('농심', '{농심}'), ('오리온', '{오리온}'), ('해태', '{해태}'), ('크라운', '{크라운제과}'),
  ('빙그레', '{빙그레}'), ('매일', '{매일유업}'), ('상하목장', '{매일유업}'), ('남양', '{남양유업,남양에프앤비}'), ('서울우유', '{서울우유}'),
  ('풀무원', '{풀무원}'), ('동원', '{동원}'), ('목우촌', '{목우촌,농협}'), ('하림', '{하림}'), ('팔도', '{팔도}'),
  ('삼양', '{삼양식품}'), ('광동', '{광동}'), ('동아', '{동아오츠카}'), ('동아오츠카', '{동아오츠카}'), ('웅진', '{웅진식품}'),
  ('일화', '{일화}'), ('사조', '{사조}'), ('대상', '{대상}'), ('청정원', '{대상}'), ('종가', '{대상}'), ('종가집', '{대상}'), ('비락', '{비락}'),
  ('파리바게뜨', '{파리크라상}'), ('파리바게트', '{파리크라상}'),
  ('야쿠르트', '{한국야쿠르트,에치와이,야쿠르트}'), ('hy', '{한국야쿠르트,에치와이,야쿠르트}'),
  ('코카콜라', '{코카콜라,COCACOLA,LG생활건강,해태HTB,해태에이치티비}'),
  ('몬스터', '{코카콜라,COCACOLA,해태에이치티비,MONSTER}'),
  ('스타벅스', '{스타벅스,동서식품,네슬레,NESTLE}'),
  ('하겐다즈', '{HAAGEN,하겐다즈}'), ('허쉬', '{HERSHEY,THE HERSHEY,허쉬}'), ('페레로', '{FERRERO,페레로}'), ('킨더', '{FERRERO,페레로}'),
  ('하리보', '{HARIBO,하리보}'), ('켈로그', '{켈로그,농심켈로그,KELLOGG}'), ('레드불', '{RED BULL,레드불,RAUCH}')
on conflict (brand) do update set makers = excluded.makers;

-- 질의 표기 → 데이터 표기(정규화 전 소문자 문자열에서 바꾼다)
create table if not exists name_spellings (
  spelling text primary key,
  canonical text not null
);
alter table name_spellings enable row level security;
revoke all on name_spellings from anon, authenticated;
grant all on name_spellings to service_role;
insert into name_spellings (spelling, canonical) values ('2%', '이프로')
on conflict (spelling) do update set canonical = excluded.canonical;

-- ---------------------------------------------------------------- 질의 → 찾을 이름(상품)
-- 후보 이름마다: 원래 이름(stripped=false), 첫 낱말을 뗀 이름(전과 같은 브랜드 후보), 아는 브랜드 낱말을 모두 뗀 이름(stripped=true).
--  frags  = 질의에 든 아는 브랜드의 제조사 조각(정규화, 낱말 순서 → brand_makers 순서). 비어 있으면 아는 브랜드 없음.
--  qwords = 여러 낱말 이름의 첫 낱말(정규화, 2글자 이상, 식품 종류·아는 브랜드 낱말 제외): 모르는 브랜드 후보. 제조사에 맞으면 브랜드 일치.
--           뗀 이름에 남는 낱말은 넣지 않는다('칠성사이다 제로'의 '제로'가 '제로베이커리'를 브랜드로 만들지 않게).
--  core   = 브랜드를 뗀 마지막 낱말('…맛' 은 건너뜀)이 식품 종류로 끝나면 그 종류(햄 · 카레 · 콘 · 칩 · 바 · 껌 …).
--  powder_q = 질의가 가루·믹스·원료 제품을 말함(그러면 제품 형태로 내리지 않는다).
--  raw    = 그 이름의 띄어 쓴 글(소문자). 아는 브랜드가 없는 질의는 전처럼 띄어 쓴 이름끼리의 유사도도 본다.
--  lastw  = 마지막 낱말(정규화). 브랜드를 붙인 원래 이름의 포함 점수는 이 낱말이 2글자 이상이거나 상품 이름에 따로 있을 때만('동원 김' ⊄ '동원 김치참치').
create or replace function product_name_variants(p_candidates text[])
returns table (ord bigint, stripped boolean, vn text, raw text, frags text[], qwords text[], core text, powder_q boolean, lastw text)
  language plpgsql stable security definer rows 6 set search_path = public, extensions as $$
declare
  kinds constant text[] := array['아이스크림', '요구르트', '요거트', '초콜릿', '소시지', '비엔나', '라면', '우유', '카레', '짜장', '짬뽕',
    '만두', '교자', '김치', '치즈', '두부', '쿠키', '젤리', '사탕', '캔디', '주스', '커피', '라떼', '라테', '콜라', '사이다',
    '치킨', '피자', '햄', '콘', '칩', '바', '껌', '빵', '면', '떡', '밥', '차', '죽', '탕'];
  c text; o bigint := 0; low text; sp record;
  w text[]; wn text[]; isb boolean[]; fr text[]; qw text[]; rest text[]; seen text[];
  v0 text; v1 text; v2 text; raw0 text; raw1 text; raw2 text; cw text; k text; pq boolean;
begin
  foreach c in array coalesce(p_candidates, '{}'::text[]) loop
    o := o + 1;
    low := lower(normalize(btrim(coalesce(c, '')), NFKC));
    continue when low = '';
    for sp in select s.spelling, s.canonical from name_spellings s loop
      low := replace(low, lower(normalize(sp.spelling, NFKC)), lower(sp.canonical));
    end loop;
    w := regexp_split_to_array(btrim(low), '\s+');
    wn := array(select food_name_norm(x) from unnest(w) with ordinality u(x, n) order by n);
    isb := array(select exists (select 1 from brand_makers b where food_name_norm(b.brand) = x) from unnest(wn) with ordinality u(x, n) order by n);
    fr := array(select m from (select food_name_norm(m) as m, min(u.n * 100 + mm.j) as pos
      from unnest(wn) with ordinality u(x, n) join brand_makers b on food_name_norm(b.brand) = u.x, unnest(b.makers) with ordinality mm(m, j)
      group by 1) z order by pos);
    qw := case when cardinality(wn) >= 2 and length(wn[1]) >= 2 and not wn[1] = any(kinds) and not isb[1] then array[wn[1]] else '{}' end;
    rest := array(select x from unnest(wn, isb) u(x, b) where not b and x <> '');
    v0 := array_to_string(wn, '');
    v1 := case when cardinality(w) >= 2 then array_to_string(wn[2:], '') end;
    v2 := case when true = any(isb) then array_to_string(rest, '') end;
    raw0 := array_to_string(w, ' ');
    raw1 := array_to_string(w[2:], ' ');
    raw2 := array_to_string(array(select x from unnest(w, isb) u(x, b) where not b), ' ');
    pq := v0 ~ '분말|파우더|믹스|생지|원료|베이스|농축';
    cw := (select x from unnest(rest) with ordinality u(x, n) where x !~ '맛$' order by n desc limit 1);
    k := (select t from unnest(kinds) t where cw like '%' || t order by length(t) desc limit 1);
    seen := '{}';
    if v0 <> '' then
      ord := o; stripped := false; vn := v0; raw := raw0; frags := fr; qwords := qw; core := k; powder_q := pq; lastw := wn[cardinality(wn)]; return next; seen := seen || v0;
    end if;
    if coalesce(v1, '') <> '' and not v1 = any(seen) then
      ord := o; stripped := true; vn := v1; raw := raw1; frags := fr; qwords := qw; core := k; powder_q := pq; lastw := wn[cardinality(wn)]; return next; seen := seen || v1;
    end if;
    if coalesce(v2, '') <> '' and not v2 = any(seen) then
      ord := o; stripped := true; vn := v2; raw := raw2; frags := fr; qwords := qw; core := k; powder_q := pq; lastw := wn[cardinality(wn)]; return next;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- 상품 매칭
-- 04 §4.2 임계값 그대로(≥0.45 자동 / 0.25~0.45 후보 칩 / <0.25 미매칭). 후보 행:
--  A. 정규화 이름 같음 → 점수 1.
--  B. 정규화 이름 trgm 유사도 상위 20. 아는 브랜드가 없는 질의는 띄어 쓴 이름끼리의 유사도(전과 같은 값)가 더 크면 그 값
--     (공백을 빼면 짧은 질의의 유사도가 낮아진다: '진라면' ~ '진라면(매운맛)'). 브랜드 질의는 '오리온 …' 같은 브랜드 낱말만 같은 상품이 오르지 않게 정규화 값만.
--  C. 브랜드를 뗀 이름이 이름에 든, 그 브랜드 제조사(앞글자) 상품 상위 20('남양 17차' → '몸이맑아지는시간17차').
-- 브랜드 일치(brand_hit) = 제조사가 질의의 아는 브랜드(어느 낱말이든)의 제조사 조각이나 첫 낱말에 맞는다(maker_match_pos).
-- 상품 이름의 브랜드 낱말만으로는 보지 않는다(다른 회사의 협업·표기 '목우촌 주부9단 햄김치볶음밥' · '롯데드림카카오닙스'가 있어서).
-- 다만 브랜드까지 붙인 이름이 통째로 같으면(위탁 제조 '스타벅스 다크초콜릿' · STEENLAND) 브랜드 일치로 본다.
-- 브랜드를 뗀 이름은 브랜드 일치일 때만 센다(I1).
-- 브랜드 일치 행은 뗀 이름이 이름에 통째로 들면 점수를 0.6 + 0.2 × (뗀 이름 길이 ÷ 상품 이름 길이) 이상으로 본다(자동 매칭).
-- 브랜드를 떼지 않은 원래 이름은 마지막 낱말이 2글자 이상이거나 상품 이름에 따로(띄어 쓴 낱말로) 있을 때만('동원 김'이 '동원 김치참치'에 들어도 아님).
-- 고르는 순서:
--  1) 브랜드: 브랜드 일치 행이 하나라도 있으면 브랜드가 다른 제조사 행은 뒤로(다른 제조사만 있을 때만 그중에서 고른다).
--  2) 같은 브랜드 묶음의 최고 점수 − 0.1 안의 행끼리:
--     제품 형태 — 질의가 가루·믹스·원료가 아니면 이름·분류가 분말/파우더/믹스/생지/반죽/원료/베이스/농축액/시럽/조미료·인스턴트커피인 행을 뒤로,
--     핵심어 — 이름이 질의의 식품 종류(햄 · 콘 …)로 끝나는 행을 먼저(햄김치볶음밥은 '햄'으로 끝나지 않아 '…햄'보다 뒤).
--       핵심어는 브랜드를 뗀 마지막 낱말이 그 종류로 끝날 때만('주부9단 햄' → 햄, '부라보콘' → 콘). 가벼운 우선이라 0.1 안에서만 본다.
--     기본 맛 — 최고 점수 − 0.05 안이면 오리지널·클래식·플레인·바닐라 이름을 먼저(맛을 말하지 않은 '롯데 몽쉘' → '몽쉘 오리지널').
--  3) 점수, 브랜드 조각 순서(코카콜라 → 코카콜라음료 먼저), 원래 이름, 후보 순서.
-- 후보 이름 중 하나라도 아는 브랜드가 있는데 고른 상품이 그 브랜드 일치가 아니면 자동 대신 후보 칩(확인 필요).
-- 마시는·먹는 질의에 가루 상품(제품 형태)을 골랐거나, 핵심어가 다른 음식의 꾸밈말로만 든 상품('김치덮밥')을 골라도 후보 칩.
-- 같은 이름(정규화) 다른 상품의 g당 kcal 이 30% 넘게(차이 0.1 초과) 다르면 후보 칩(D64). 브랜드 일치로 고른 상품은 같은 브랜드 상품끼리만 본다.
create or replace function map_product_pick(p_candidates text[]) returns jsonb
  language sql stable security definer set search_path = public, extensions set jit = off as $$
  with v as materialized (select * from product_name_variants(p_candidates)),
  -- 후보 행에 상품 칸을 함께 싣는다(다시 food_db_cache 와 조인하면 계획기가 전체 색인을 훑는다)
  hits as materialized (
    select f.food_code, f.name_kr, f.kcal, f.serving_g, f.name_norm, f.maker, f.category, v.ord, v.stripped, v.vn, 1::real as sim
    from v join food_db_cache f on f.is_product and f.name_norm = v.vn
    union all
    select m.food_code, m.name_kr, m.kcal, m.serving_g, m.name_norm, m.maker, m.category, v.ord, v.stripped, v.vn, m.sim from v, lateral (
      select f.food_code, f.name_kr, f.kcal, f.serving_g, f.name_norm, f.maker, f.category,
        case when cardinality(v.frags) = 0 then greatest(similarity(f.name_norm, v.vn), similarity(f.name_kr, v.raw))
          else similarity(f.name_norm, v.vn) end as sim
      from food_db_cache f where f.is_product and f.name_norm % v.vn order by 8 desc, 1 limit 20) m
    union all
    select m.food_code, m.name_kr, m.kcal, m.serving_g, m.name_norm, m.maker, m.category, v.ord, v.stripped, v.vn, m.sim from v, lateral (
      select f.food_code, f.name_kr, f.kcal, f.serving_g, f.name_norm, f.maker, f.category, similarity(f.name_norm, v.vn) as sim
      from unnest(v.frags) fr join food_db_cache f on f.is_product
        and food_maker_key(f.maker) collate "C" >= fr collate "C" and food_maker_key(f.maker) collate "C" < (fr || chr(1114111)) collate "C"
        and strpos(f.name_norm, v.vn) > 0
      order by length(f.name_norm), 1 limit 20) m
    where v.stripped and length(v.vn) >= 2),
  r0 as (
    select h.food_code, h.name_kr, h.kcal, h.serving_g, h.name_norm, h.ord, h.stripped, h.vn, h.sim, c.core, c.powder_q, c.lastw,
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
  -- 애매하면 고른 상품 → 같은 이름 상품들 → 나머지, 아니면 고르는 순서대로(첫 칩 = 고른 상품). 최대 10개
  chips as (
    select * from (
      select distinct on (food_code) * from (
        select food_code, name_kr, kcal, score, 2 as grp, rk from r
        union all select food_code, name_kr, kcal, score, 1, 0 from alts
        union all select b.food_code, b.name_kr, b.kcal, b.score, 0, 0 from best b, amb where amb.yes
      ) u order by food_code, grp, rk) d
    order by grp, rk, food_code limit 10),
  -- 후보 이름 중 하나라도 아는 브랜드가 있으면, 고른 상품이 그 브랜드 일치일 때만 자동('롯데 자일리톨 껌' · '자일리톨' 처럼 브랜드 없는 후보로 우회하지 않게)
  auto as (select b.score >= 0.45 and not amb.yes and not b.form_bad and not b.core_compound
    and ((b.brand_hit and cardinality(b.frags) > 0) or not exists (select 1 from v where cardinality(v.frags) > 0)) as yes
    from best b, amb)
  select jsonb_build_object(
    'match', case when coalesce(auto.yes, false) then 'auto' when b.score >= 0.25 then 'chips' else 'none' end,
    'food_code', case when auto.yes then b.food_code end,
    'kcal', case when auto.yes then b.kcal end,
    'score', b.score,
    'is_product', true,
    'ambiguous', amb.yes,
    'chips', (select coalesce(jsonb_agg(jsonb_build_object('food_code', z.food_code, 'name', z.name_kr, 'kcal', z.kcal, 'score', z.score,
      'is_product', true) order by z.grp, z.rk, z.food_code), '[]') from chips z))
  from (select 1) one cross join amb left join best b on true left join auto on true
$$;

-- 음식 매칭(한 종류): 20261004001400 의 map_food_pick 에서 p_product = false 인 경로 그대로
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
    'score', b.score,
    'is_product', false,
    'ambiguous', false,
    'chips', (select coalesce(jsonb_agg(jsonb_build_object('food_code', z.food_code, 'name', z.name_kr, 'kcal', z.kcal, 'score', z.score,
      'is_product', z.is_product) order by z.score desc, z.food_code), '[]') from chips z))
  from (select 1) one left join best b on true
$$;

-- 한 종류 매칭: 상품은 map_product_pick, 음식은 map_dish_pick(map_food_candidates 는 그대로 이 함수를 부른다)
create or replace function map_food_pick(p_candidates text[], p_product boolean) returns jsonb
  language plpgsql stable security definer set search_path = public, extensions set jit = off as $$
begin
  if coalesce(p_product, false) then return map_product_pick(p_candidates); end if;
  return map_dish_pick(p_candidates);
end $$;

revoke execute on function product_name_variants(text[]), map_product_pick(text[]), map_dish_pick(text[]), map_food_pick(text[], boolean)
  from public, anon, authenticated;
grant execute on function product_name_variants(text[]), map_product_pick(text[]), map_dish_pick(text[]), map_food_pick(text[], boolean)
  to service_role;

analyze food_db_cache;
reset lock_timeout;
reset statement_timeout;
