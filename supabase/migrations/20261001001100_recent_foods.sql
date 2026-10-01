-- 최근 음식(04 §4.4: 30일 확정 20개). 본인 끼니만(security invoker → meals·meal_items RLS).
-- 1인분 kcal = 식약처 DB 값 → 초안 때 저장한 serving_kcal → 확정값을 분량·개수·국물로 되돌린 값 순.
create or replace function recent_foods(p_limit int default 20) returns table (name text, food_code text, kcal numeric, last_used timestamptz)
  language sql stable as $$
  select name, food_code, kcal, last_used from (
    select distinct on (coalesce(i.food_code, i.chosen_name))
      i.chosen_name as name,
      i.food_code,
      r1(coalesce(f.kcal, i.serving_kcal,
        i.confirmed_kcal / nullif(i.portion_multiplier * i.count * case when i.broth_off then 0.6 else 1 end * coalesce(i.bite_fraction, 1), 0))) as kcal,
      coalesce(m.confirmed_at, m.captured_at) as last_used
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
revoke execute on function recent_foods(int) from public, anon;
grant execute on function recent_foods(int) to authenticated, service_role;

-- 음식 검색은 pg_trgm(similarity·%) 에 의존한다. 확장이 public(로컬)·extensions(Supabase) 어디에 있든
-- 참가자 권한으로 동작하도록 읽기 전용 security definer 로 돌린다(음식 DB 는 공개 데이터, 쓰기 없음).
alter function food_search(text) security definer set search_path = public, extensions;
alter function map_food_candidates(text[]) security definer set search_path = public, extensions;
