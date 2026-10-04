-- 낱개 포장 한 개(D67).
-- 1) AI 가 여러 개입 상자에서 꺼낸 낱개 포장 하나로 본 포장 상품 항목: meal_items.ai_single_piece(기본 false).
--    analyze-meal 이 초안에 쓰고 앱 P7 이 '몇 개입' 배너를 띄운다. 확정은 항목을 다시 쓰므로(confirm_meal 그대로) 확정 뒤에는 false.
-- 2) AI 가 낱개 포장 하나로 본 항목을 '몇 개입'으로 1개 단위로 바꾼 것은 사용자의 과소 입력이 아니라 단위 정정이다. meal-confirm 이
--    확정 직전에 부르는 rebase_ai_kcal_for_pieces 가 그 항목의 AI 초안 kcal 을 같은 1개 단위로 맞춰(분석 때 개입 수가 있었으면 나왔을 값),
--    confirm_meal 의 하향 수정 판정(AI 대비 −50% 초과 → downward_edit)이 단위 차이로 올라가지 않게 한다.
--    AI 가 낱개로 보지 않은 항목은 맞추지 않는다(사용자가 넣은 개입 수만으로 검토 기준을 낮추지 않는다). 맞춘 것은 감사 기록에 남긴다.

alter table meal_items add column if not exists ai_single_piece boolean not null default false;

-- 끼니 주인이 지금 확정하려는 항목([p_items], meal-confirm 본문) 중 포장 상품이 내 개입 수의 1개 kcal(없으면 1회분 kcal)로 왔고
-- AI 가 낱개 포장 하나로 본 초안 항목(같은 food_code, AI 항목, ai_single_piece)은 다른 단위였으면, 그 초안 항목의 AI kcal =
-- 1개 kcal × AI 배수 × AI 개수(소수 1자리)로, 끼니 AI kcal 은 항목 합으로 다시 쓰고 바꾼 항목마다 감사 기록(ai_kcal_rebased_pieces)을 남긴다.
-- 초안·자동 확정 끼니만, 버전이 맞을 때만(버전은 올리지 않는다 — 확정이 올린다). 개수를 AI 보다 줄인 몫은 그대로 남아 하향 수정 판정을 받는다.
-- 끼니 AI kcal 을 돌려준다(대상 끼니가 아니면 null).
create or replace function rebase_ai_kcal_for_pieces(p_user uuid, p_meal uuid, p_items jsonb, p_version int)
  returns numeric language plpgsql as $$
declare
  m meals;
  v_challenge uuid;
  v_old numeric;
  it record;
  v_done jsonb := '[]';
begin
  select * into m from meals where id = p_meal for update;
  select p.challenge_id into v_challenge from participants p where p.id = m.participant_id and p.user_id = p_user;
  if m.id is null or v_challenge is null or m.status not in ('draft', 'auto') or m.version <> p_version or m.locked_at is not null then
    return null;
  end if;
  v_old := m.ai_kcal;
  for it in
    with sent as (
      select x ->> 'food_code' as food_code, (x ->> 'serving_kcal')::numeric as serving
      from jsonb_array_elements(case when jsonb_typeof(p_items) = 'array' then p_items else '[]' end) x
      where x ->> 'food_code' is not null and jsonb_typeof(x -> 'serving_kcal') = 'number'
    ), unit as (
      -- 이 사용자의 지금 1단위 kcal: 개입 수가 있으면 1개 kcal, 없으면 1회분 kcal(포장 크기를 아는 상품만)
      select f.food_code, u.pieces, coalesce(product_piece_kcal(f.kcal, f.serving_g, f.package_g, u.pieces), f.kcal) as kcal
      from food_db_cache f
      left join user_product_pieces u on u.user_id = p_user and u.food_code = f.food_code
      where f.is_product and f.package_g > 0 and f.food_code in (select food_code from sent)
    ), picked as (
      -- 앱과 서버의 소수 1자리 반올림이 갈릴 수 있어 0.1 차이까지 같은 값으로 본다(앱 ProductUnit.piecesOf 와 같음)
      select distinct on (s.food_code) s.food_code, s.serving, unit.pieces
      from sent s join unit on unit.food_code = s.food_code
      where abs(s.serving - unit.kcal) < 0.11
      order by s.food_code, abs(s.serving - unit.kcal)
    )
    select i.id, i.food_code, i.ai_kcal as old_ai, r1(p.serving * i.portion_multiplier * i.count) as new_ai, p.pieces
    from meal_items i join picked p on p.food_code = i.food_code
    where i.meal_id = m.id and i.input_type = 'ai' and i.ai_single_piece and coalesce(i.ai_kcal, 0) > 0
      and i.serving_kcal is not null and abs(i.serving_kcal - p.serving) >= 0.11
    order by i.id
  loop
    if it.new_ai is distinct from it.old_ai then
      update meal_items set ai_kcal = it.new_ai, updated_at = now() where id = it.id;
      v_done := v_done || jsonb_build_object('item', it.id, 'food_code', it.food_code, 'old_ai_kcal', it.old_ai, 'new_ai_kcal', it.new_ai,
        'pieces', it.pieces);
    end if;
  end loop;
  if jsonb_array_length(v_done) > 0 then
    update meals set ai_kcal = (select r1(sum(ai_kcal)) from meal_items where meal_id = m.id) where id = m.id returning * into m;
    for it in select value as d from jsonb_array_elements(v_done) loop
      perform write_audit(v_challenge, p_user, 'participant', 'ai_kcal_rebased_pieces', jsonb_build_object('meal_id', m.id) || it.d,
        jsonb_build_object('meal_ai_kcal', v_old), jsonb_build_object('meal_ai_kcal', m.ai_kcal));
    end loop;
  end if;
  return m.ai_kcal;
end $$;

revoke execute on function rebase_ai_kcal_for_pieces(uuid, uuid, jsonb, int) from public, anon, authenticated;
grant execute on function rebase_ai_kcal_for_pieces(uuid, uuid, jsonb, int) to service_role;
