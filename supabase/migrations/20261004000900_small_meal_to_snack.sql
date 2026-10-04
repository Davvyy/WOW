-- 끼니 칸(아침·점심·저녁) 기록을 간식 기준(snack_kcal, 150) 미만으로 확정하면 간식 칸으로 옮긴다(D59).
-- 간식 수준 기록은 원래도 끼니 칸을 채우지 않아 점수는 같고, 화면에서 "저녁인데 간식으로 계산"되는 오해만 없앤다.
-- 원래 칸은 meals.main_slot 에 남겨, 나중에 끼니 수준으로 고치면 원래 칸으로 되돌린다.

alter table meals add column main_slot meal_slot;
comment on column meals.main_slot is '간식 수준으로 확정돼 간식 칸으로 옮기기 전의 끼니 칸(D59). 끼니 수준으로 고치면 되돌리고 비운다';

-- 원래 정의(20261004000700_confirm_keeps_item_detail.sql)에서 바꾼 것: 확정 때 칸 옮기기, 응답에 slot.
create or replace function confirm_meal(p_user uuid, p_meal uuid, p_items jsonb, p_version int, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  m meals;
  p participants;
  r challenge_rules;
  it jsonb;
  v_kcal numeric;
  v_total numeric := 0;
  v_serving numeric;
  v_final boolean;
  v_finalized_at timestamptz;
  v_hash text := md5(coalesce(p_items, '[]')::text);
  v_ratio numeric;
  v_flags text[] := '{}';
  v_score daily_scores;
  v_slot meal_slot;
  v_main meal_slot;
begin
  select * into m from meals where id = p_meal for update;
  if not found then raise exception 'meal not found' using errcode = 'PT404'; end if;
  select * into p from participants where id = m.participant_id;
  if p.user_id is distinct from p_user then raise exception 'not your meal' using errcode = 'PT403'; end if;
  r := engine_rules(p.challenge_id);
  if m.version <> p_version then raise exception 'version mismatch' using errcode = 'PT412'; end if;
  if m.status in ('void', 'skipped') then raise exception 'meal not editable' using errcode = 'PT422'; end if;

  select is_final, finalized_at into v_final, v_finalized_at from daily_scores where participant_id = p.id and local_date = m.local_date;
  if m.locked_at is not null or (coalesce(v_final, false) and p_now > coalesce(v_finalized_at, p_now) + r.edit_window) then
    raise exception 'edit window closed' using errcode = 'PT422'; -- 04 T19: 확정 후 48h 초과 수정 거부
  end if;


  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'))
  loop
    v_serving := coalesce((it ->> 'serving_kcal')::numeric, (select kcal from food_db_cache where food_code = it ->> 'food_code'));
    if v_serving is null then raise exception 'item kcal unknown: %', it ->> 'chosen_name' using errcode = 'PT422'; end if;
    v_kcal := meal_item_kcal(v_serving, coalesce((it ->> 'portion_multiplier')::numeric, 1), coalesce((it ->> 'count')::int, 1),
      coalesce((it ->> 'broth_off')::boolean, false), coalesce((it ->> 'bite_fraction')::numeric, 1), r);
    if coalesce((it ->> 'eaten')::boolean, true) then v_total := v_total + v_kcal; end if;
  end loop;

  -- 같은 확정값·같은 항목이면 아무것도 바꾸지 않는다(멱등)
  if m.status in ('confirmed', 'auto', 'corrected') and m.confirmed_kcal = v_total
     and m.items_hash is not distinct from v_hash then
    perform confirm_meal_copies(p_user, m, p_items, p_now); -- 같은 내용 재전송으로 앞서 실패한 복사본을 복구한다
    return jsonb_build_object('meal_id', m.id, 'confirmed_kcal', m.confirmed_kcal, 'delta_ratio', m.delta_ratio,
      'version', m.version, 'unchanged', true, 'slot', m.slot);
  end if;

  delete from meal_items where meal_id = m.id;
  insert into meal_items (meal_id, name_candidates, chosen_name, food_code, input_type, count, portion_bucket, portion_multiplier,
    broth_off, bite_fraction, eaten, confidence, ai_kcal, confirmed_kcal, serving_kcal, candidate_kcal, candidate_food_codes, has_broth)
  select m.id, coalesce(array(select jsonb_array_elements_text(x -> 'name_candidates')), '{}'), x ->> 'chosen_name', x ->> 'food_code',
    coalesce((x ->> 'input_type')::meal_input_type, 'ai'), coalesce((x ->> 'count')::int, 1), (x ->> 'portion_bucket')::portion_bucket,
    coalesce((x ->> 'portion_multiplier')::numeric, 1), coalesce((x ->> 'broth_off')::boolean, false),
    coalesce((x ->> 'bite_fraction')::numeric, 1), coalesce((x ->> 'eaten')::boolean, true), (x ->> 'confidence')::confidence_level,
    (x ->> 'ai_kcal')::numeric,
    meal_item_kcal(s.serving, coalesce((x ->> 'portion_multiplier')::numeric, 1), coalesce((x ->> 'count')::int, 1),
      coalesce((x ->> 'broth_off')::boolean, false), coalesce((x ->> 'bite_fraction')::numeric, 1), r),
    s.serving,
    case when jsonb_typeof(x -> 'candidate_kcal') = 'array'
      then array(select k::numeric from jsonb_array_elements_text(x -> 'candidate_kcal') k) else '{}' end,
    case when jsonb_typeof(x -> 'candidate_food_codes') = 'array'
      then array(select c from jsonb_array_elements_text(x -> 'candidate_food_codes') c) else '{}' end,
    coalesce((x ->> 'has_broth')::boolean, coalesce((x ->> 'broth_off')::boolean, false))
  from jsonb_array_elements(coalesce(p_items, '[]')) x,
    lateral (select coalesce((x ->> 'serving_kcal')::numeric,
      (select kcal from food_db_cache f where f.food_code = x ->> 'food_code')) as serving) s;

  v_ratio := case when m.ai_kcal > 0 then v_total / m.ai_kcal end;
  -- 간식 수준(snack_kcal 미만)으로 확정한 끼니 칸 기록은 간식 칸으로, 다시 끼니 수준으로 고치면 원래 칸으로(D59)
  v_slot := m.slot; v_main := m.main_slot;
  if m.slot <> 'snack' and v_total < r.snack_kcal then
    v_main := m.slot; v_slot := 'snack';
  elsif m.slot = 'snack' and m.main_slot is not null and v_total >= r.snack_kcal then
    v_slot := m.main_slot; v_main := null;
  end if;
  update meals set confirmed_kcal = v_total, delta_ratio = v_ratio, slot = v_slot, main_slot = v_main,
    status = case when coalesce(v_final, false) then 'corrected'::meal_status else 'confirmed'::meal_status end,
    confirmed_at = p_now, version = version + 1, items_hash = v_hash
  where id = m.id returning * into m;

  -- 하향 수정: AI 대비 −50% 초과 → 값 유지 + downward_edit (04 §7 #4)
  if v_ratio is not null and v_ratio < 0.5 then
    perform raise_flag(p.id, m.local_date, 'downward_edit', jsonb_build_object('key', m.id::text, 'meal_id', m.id,
      'ai_kcal', m.ai_kcal, 'confirmed_kcal', v_total), p_now);
    v_flags := v_flags || 'downward_edit'::text;
  end if;

  v_score := recompute_day(p.id, m.local_date, 'user_edit', null, p_user);
  perform confirm_meal_copies(p_user, m, p_items, p_now);
  return jsonb_build_object('meal_id', m.id, 'confirmed_kcal', v_total, 'delta_ratio', v_ratio, 'version', m.version,
    'status', m.status, 'flags', to_jsonb(v_flags), 's_d', v_score.s_d, 'is_final', v_score.is_final, 'slot', m.slot);
end $$;

-- 이미 간식 수준으로 확정된 끼니 칸 기록(확정 전 날짜만): 간식 칸으로 옮기고 그날 점수를 다시 계산한다
do $$
declare d record;
begin
  for d in
    with moved as (
      update meals m set main_slot = m.slot, slot = 'snack'
      where m.slot <> 'snack' and m.status in ('confirmed', 'corrected') and m.confirmed_kcal < (engine_rules(m.challenge_id)).snack_kcal
        and not exists (select 1 from daily_scores s where s.participant_id = m.participant_id and s.local_date = m.local_date and s.is_final)
      returning m.participant_id, m.local_date)
    select distinct participant_id, local_date from moved
  loop
    perform recompute_day(d.participant_id, d.local_date);
  end loop;
end $$;
