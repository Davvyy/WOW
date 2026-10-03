-- 확정해도 항목의 1인분 kcal(serving_kcal)·후보(candidate_kcal·candidate_food_codes)·국물 여부(has_broth)를 남긴다.
-- 전에는 확정이 항목을 다시 쓰면서 이 칸을 비워, 앱이 확정한 끼니를 다시 열면 항목이 0 kcal 로 보였고
-- 그대로 다시 확정하면 0 kcal 로 저장될 수 있었다. 이미 확정된 항목은 확정 kcal 에서 1인분 kcal 을 되살린다.

-- 원본(20261003000600_meal_fanout.sql)에서 항목 insert 만 바꿨다: 위 네 칸을 함께 저장.
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
      'version', m.version, 'unchanged', true);
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
  update meals set confirmed_kcal = v_total, delta_ratio = v_ratio,
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
    'status', m.status, 'flags', to_jsonb(v_flags), 's_d', v_score.s_d, 'is_final', v_score.is_final);
end $$;

-- 이미 확정된 항목: 1인분 kcal = 확정 kcal ÷ (배수 × 개수 × 먹은 비율 × 국물 계수)
update meal_items i set serving_kcal = round(i.confirmed_kcal / nullif(i.portion_multiplier * i.count * i.bite_fraction
    * case when i.broth_off then (default_rules()).broth_factor else 1 end, 0), 1)
where i.serving_kcal is null and i.confirmed_kcal is not null;
update meal_items set has_broth = true where broth_off and not has_broth;
