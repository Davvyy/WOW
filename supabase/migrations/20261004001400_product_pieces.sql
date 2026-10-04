-- '몇 개입' 낱개 단위(docs/02 §10 D64): 상자에 든 낱개 포장(칙촉 24개입 등)을 1개 단위로 계산한다.
-- 낱개 무게는 몰라도 포장에 적힌 '○개입' 숫자는 보이므로, 사용자가 상품마다 개입 수를 한 번 넣으면 기억한다.
--  - food_db_cache.package_g = 포장 전체 양(g·ml, 식품중량). 적재(load_processed_food.mjs)가 채우고, 모르면 null(낱개 계산 불가).
--  - 1개 양 = package_g ÷ 개입 수, 1개 kcal = kcal ÷ serving_g × 1개 양(소수 1자리). 칙촉 180g·30g당 150.3·24개입 → 7.5g·37.6 kcal.
--  - user_product_pieces: 사용자·상품별 개입 수(2~200). 본인 행만 읽고 쓴다. 앱은 set_product_pieces 로 저장·지운다.
--  - AI 초안(analyze-meal)은 포장 상품 항목이 끼니 주인의 개입 수가 있는 상품으로 매칭되면 1개 kcal 을 쓴다(product_pieces_for).
--  - 검색(food_search)·최근 음식(recent_foods)은 package_g 와 내 개입 수를 함께 준다(1개 kcal 계산은 앱이 같은 식으로).

alter table food_db_cache add column if not exists package_g numeric;

create table if not exists user_product_pieces (
  user_id uuid references auth.users on delete cascade,
  food_code text references food_db_cache on delete cascade,
  pieces int not null check (pieces between 2 and 200),
  updated_at timestamptz default now(),
  primary key (user_id, food_code)
);
create index if not exists user_product_pieces_food on user_product_pieces (food_code);

alter table user_product_pieces enable row level security;
drop policy if exists pieces_select on user_product_pieces;
drop policy if exists pieces_insert on user_product_pieces;
drop policy if exists pieces_update on user_product_pieces;
drop policy if exists pieces_delete on user_product_pieces;
create policy pieces_select on user_product_pieces for select to authenticated using (user_id = auth.uid());
create policy pieces_insert on user_product_pieces for insert to authenticated with check (user_id = auth.uid());
create policy pieces_update on user_product_pieces for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy pieces_delete on user_product_pieces for delete to authenticated using (user_id = auth.uid());
revoke all on user_product_pieces from anon;
grant select, insert, update, delete on user_product_pieces to authenticated;
grant all on user_product_pieces to service_role;

-- 1개 kcal(소수 1자리). 양·포장 크기·개수 중 하나라도 없거나 0 이하면 null
create or replace function product_piece_kcal(p_kcal numeric, p_serving_g numeric, p_package_g numeric, p_pieces int) returns numeric
  language sql immutable set search_path = public as $$
  select case when p_serving_g > 0 and p_package_g > 0 and p_pieces > 0 then r1(p_kcal / p_serving_g * (p_package_g / p_pieces)) end
$$;

-- 개입 수 저장(2~200) · 지우기(null). 포장 크기를 아는 상품만(음식·포장 크기 없는 상품·없는 코드는 PT422).
create or replace function set_product_pieces(p_food_code text, p_pieces int) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  f food_db_cache;
begin
  if v_uid is null then raise exception '로그인이 필요해요' using errcode = 'PT403'; end if;
  select * into f from food_db_cache where food_code = p_food_code;
  if not found or not f.is_product or coalesce(f.package_g, 0) <= 0 or coalesce(f.serving_g, 0) <= 0 then
    raise exception '포장 크기를 아는 상품만 낱개로 계산할 수 있어요' using errcode = 'PT422';
  end if;
  if p_pieces is null then
    delete from user_product_pieces where user_id = v_uid and food_code = p_food_code;
    return jsonb_build_object('food_code', p_food_code, 'pieces', null);
  end if;
  if p_pieces not between 2 and 200 then raise exception '개수는 2~200 사이로 넣어 주세요' using errcode = 'PT422'; end if;
  insert into user_product_pieces (user_id, food_code, pieces) values (v_uid, p_food_code, p_pieces)
    on conflict (user_id, food_code) do update set pieces = excluded.pieces, updated_at = now();
  return jsonb_build_object('food_code', p_food_code, 'pieces', p_pieces, 'piece_g', r1(f.package_g / p_pieces),
    'piece_kcal', product_piece_kcal(f.kcal, f.serving_g, f.package_g, p_pieces));
end $$;

-- 서비스(analyze-meal) 전용: 끼니 주인이 넣은 개입 수가 있는 상품 → 1개 양·kcal
create or replace function product_pieces_for(p_user uuid, p_codes text[])
returns table (food_code text, pieces int, piece_g numeric, piece_kcal numeric)
  language sql stable security definer set search_path = public as $$
  select u.food_code, u.pieces, r1(f.package_g / u.pieces), product_piece_kcal(f.kcal, f.serving_g, f.package_g, u.pieces)
  from user_product_pieces u join food_db_cache f on f.food_code = u.food_code
  where u.user_id = p_user and u.food_code = any(p_codes) and f.is_product and f.package_g > 0 and f.serving_g > 0
$$;

-- 음식 검색(20261004001300 과 같은 결과·순서) + 상품의 포장 크기와 내 개입 수(포장 크기를 아는 상품만)
drop function if exists food_search(text);
create function food_search(q text)
returns table (food_code text, name_kr text, kcal numeric, serving_g numeric, score real, is_product boolean, maker text, unit_label text,
  package_g numeric, pieces int)
  language sql stable security definer set search_path = public, extensions as $$
  select x.*, f.package_g, case when f.package_g > 0 then u.pieces end from (
    select * from (select * from food_match(q, false) union all select * from food_match(q, true)) y
    order by y.score desc, y.is_product, y.name_kr, y.food_code limit 20
  ) x
  left join food_db_cache f on x.is_product and f.food_code = x.food_code
  left join user_product_pieces u on u.user_id = auth.uid() and u.food_code = x.food_code
  order by x.score desc, x.is_product, x.name_kr, x.food_code
$$;

-- 최근 음식(20261004001300 과 같음) + 1회분 양·포장 크기·내 개입 수(검색과 같은 칸)
drop function if exists recent_foods(int);
create function recent_foods(p_limit int default 20)
returns table (name text, food_code text, kcal numeric, last_used timestamptz, is_product boolean, maker text, unit_label text,
  serving_g numeric, package_g numeric, pieces int)
  language sql stable as $$
  select name, food_code, kcal, last_used, is_product, maker, unit_label, serving_g, package_g, pieces from (
    select distinct on (coalesce(i.food_code, i.chosen_name))
      i.chosen_name as name,
      i.food_code,
      r1(coalesce(f.kcal, i.serving_kcal,
        i.confirmed_kcal / nullif(i.portion_multiplier * i.count * case when i.broth_off then 0.6 else 1 end * coalesce(i.bite_fraction, 1), 0))) as kcal,
      coalesce(m.confirmed_at, m.captured_at) as last_used,
      coalesce(f.is_product, false) as is_product, f.maker, f.unit_label,
      f.serving_g, case when f.is_product then f.package_g end as package_g,
      case when f.is_product and f.package_g > 0 then u.pieces end as pieces
    from meal_items i
    join meals m on m.id = i.meal_id
    left join food_db_cache f on f.food_code = i.food_code
    left join user_product_pieces u on u.user_id = auth.uid() and u.food_code = i.food_code
    where m.status in ('confirmed', 'auto', 'corrected') and i.eaten and i.chosen_name is not null
      and coalesce(m.confirmed_at, m.captured_at) >= now() - interval '30 days'
      and m.participant_id in (select id from participants where user_id = auth.uid())
    order by coalesce(i.food_code, i.chosen_name), coalesce(m.confirmed_at, m.captured_at) desc
  ) x
  where kcal is not null and kcal > 0
  order by last_used desc
  limit greatest(1, least(coalesce(p_limit, 20), 50))
$$;

revoke execute on function product_pieces_for(uuid, text[]) from public, anon, authenticated;
grant execute on function product_pieces_for(uuid, text[]) to service_role;
revoke execute on function set_product_pieces(text, int), food_search(text), recent_foods(int) from public, anon;
grant execute on function set_product_pieces(text, int), food_search(text), recent_foods(int) to authenticated, service_role;
grant execute on function product_piece_kcal(numeric, numeric, numeric, int) to authenticated, service_role;
