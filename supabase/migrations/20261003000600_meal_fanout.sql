-- 끼니 기록 공유(docs/02 D52): 한 번 올린 끼니를 참가 중인 모든 챌린지에 같은 값으로 넣는다.
-- 대표 끼니(record_group_id = id)는 사용자가 다루는 끼니, 복사본(record_group_id = 대표 id)은 다른 챌린지의 같은 끼니.
-- 분석 결과는 트리거가, 확정·건너뜀·직접 입력은 쓰기 함수가 그룹 전체에 반영한다. 운영자 판정은 그 챌린지 끼니에만.
alter table meals add column record_group_id uuid;
update meals set record_group_id = id;
alter table meals alter column record_group_id set not null;
create index meals_group_idx on meals (record_group_id);
create or replace function meals_group_default() returns trigger language plpgsql as $$
begin
  new.record_group_id := coalesce(new.record_group_id, new.id);
  return new;
end $$;
create trigger meals_group_default before insert on meals for each row execute function meals_group_default();

-- 같은 사진을 여러 챌린지의 끼니가 쓴다: 사진 1장당 참가자별 1끼
drop index meals_photo_uidx;
create unique index meals_photo_uidx on meals (participant_id, photo_id) where photo_id is not null;

-- 참가자에게는 대표 끼니만(이전 앱에 중복이 보이지 않게). 운영자는 자기 챌린지 끼니 전부.
drop policy meals_read on meals;
create policy meals_read on meals for select to authenticated
  using ((owns_participant(participant_id) and record_group_id = id) or is_challenge_operator(challenge_id));

-- 참가 중인 챌린지 전부(최근 참가 순). active_participant 의 여러 건 버전.
create or replace function active_participations(p_user uuid, p_statuses challenge_status[] default array['checking', 'running']::challenge_status[])
  returns setof participants language sql stable as $$
  select p.* from participants p join challenges c on c.id = p.challenge_id
  where p.user_id = p_user and c.status = any (p_statuses) and p.status in ('active', 'record_mode', 'excluded')
  order by p.joined_at desc
$$;

-- 대표 끼니의 분석 결과(captured → draft/failed)를 아직 분석 전인 복사본에 옮긴다(Edge analyze-meal 은 대표만 분석)
create or replace function meals_group_sync() returns trigger language plpgsql as $$
declare c meals;
begin
  if new.id = new.record_group_id and old.status = 'captured' and new.status in ('draft', 'failed') then
    for c in select * from meals where record_group_id = new.id and id <> new.id and status = 'captured' for update
    loop
      insert into meal_items (meal_id, name_candidates, chosen_name, food_code, input_type, count, portion_bucket, portion_multiplier,
        broth_off, bite_fraction, eaten, confidence, match_score, needs_check, ai_kcal, confirmed_kcal, has_broth, candidate_kcal,
        candidate_food_codes, serving_kcal)
      select c.id, name_candidates, chosen_name, food_code, input_type, count, portion_bucket, portion_multiplier,
        broth_off, bite_fraction, eaten, confidence, match_score, needs_check, ai_kcal, confirmed_kcal, has_broth, candidate_kcal,
        candidate_food_codes, serving_kcal
      from meal_items where meal_id = new.id;
      update meals set status = new.status, ai_kcal = new.ai_kcal, engine = new.engine where id = c.id;
      if c.counted then perform recompute_day(c.participant_id, c.local_date); end if;
    end loop;
  end if;
  return new;
end $$;
create trigger meals_group_sync after update of status on meals for each row execute function meals_group_sync();

-- ---------------------------------------------------------------- 사진 끼니 만들기 (API #9)
create or replace function create_meal(p_user uuid, p_photo uuid, p_queued boolean default false, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  ph photos; p participants; ch challenges; r challenge_rules;
  v_tag_at timestamptz := p_now;
  v_diff interval;
  v_late boolean := false;
  v_counted boolean := true;
  v_date date; v_slot meal_slot;
  v_engine ai_engine := 'none';
  v_meal uuid;
  v_dup boolean;
  q participants; qch challenges; v_copy uuid; v_qcounted boolean;
begin
  select * into ph from photos where id = p_photo;
  if not found then raise exception 'photo not found' using errcode = 'PT404'; end if;
  select * into p from participants where id = ph.participant_id;
  if p.user_id is distinct from p_user then raise exception 'not your photo' using errcode = 'PT403'; end if;
  if ph.verified_at is null then raise exception '사진 업로드 확인 전이에요' using errcode = 'PT422'; end if;
  if exists (select 1 from meals where photo_id = p_photo and participant_id = p.id) then
    return (select jsonb_build_object('meal_id', id, 'status', status, 'local_date', local_date, 'slot', slot, 'replayed', true)
      from meals where photo_id = p_photo and participant_id = p.id);
  end if;
  select * into ch from challenges where id = p.challenge_id;
  r := engine_rules(ch.id);

  if p_queued and ph.client_captured_at is not null and ph.client_captured_at < p_now then
    v_diff := p_now - ph.client_captured_at;
    if v_diff > interval '30 minutes' then
      v_late := true;
      if exists (select 1 from daily_scores where participant_id = p.id and local_date = kst_date(ph.client_captured_at) and is_final) then
        v_tag_at := ph.client_captured_at; v_counted := false;
      elsif v_diff <= r.late_upload_window then
        v_tag_at := ph.client_captured_at;
      end if;
    end if;
  end if;
  v_date := kst_date(v_tag_at);
  v_slot := slot_for(v_tag_at, r);
  if v_counted and (v_date < ch.start_date or v_date > ch.end_date) then
    raise exception '챌린지 기간 밖의 사진이에요' using errcode = 'PT422';
  end if;
  if v_counted and exists (select 1 from daily_scores where participant_id = p.id and local_date = v_date and is_final) then
    v_counted := false; -- 확정된 날짜로 태그되는 경우(서버 시각 기준)도 미인정
  end if;
  if exists (select 1 from consents where user_id = p_user and type = 'overseas_ai' and revoked_at is null) then
    v_engine := 'gemini';
  end if;

  insert into meals (participant_id, challenge_id, local_date, slot, status, photo_id, engine, late_upload, counted, captured_at)
  values (p.id, p.challenge_id, v_date, v_slot, 'captured', p_photo, v_engine, v_late, v_counted, p_now)
  returning id into v_meal;

  if v_late then
    perform raise_flag(p.id, v_date, 'late_upload', jsonb_build_object('key', v_meal::text, 'meal_id', v_meal,
      'client_captured_at', ph.client_captured_at, 'server_received_at', p_now, 'counted', v_counted), p_now);
  end if;
  -- 사진 SHA-256 중복(본인·타인, 서버 해시 기준) → dup_photo 검토 중
  select exists (select 1 from photos o where o.sha256_server = ph.sha256_server and o.id <> ph.id) into v_dup;
  if v_dup then
    perform raise_flag(p.id, v_date, 'dup_photo', jsonb_build_object('key', v_meal::text, 'meal_id', v_meal, 'photo_id', p_photo), p_now);
  end if;
  if v_counted then perform recompute_day(p.id, v_date); end if;

  -- 기록 공유(D52): 참가 중인 다른 챌린지에 같은 사진의 끼니를 복사한다. 플래그는 각 챌린지 운영자가 보도록 복사본에도.
  for q in select * from active_participations(p_user) where id <> p.id
  loop
    select * into qch from challenges where id = q.challenge_id;
    continue when v_date < qch.start_date or v_date > qch.end_date or v_date < q.check_start;
    v_qcounted := v_counted and not exists (select 1 from daily_scores where participant_id = q.id and local_date = v_date and is_final);
    insert into meals (participant_id, challenge_id, local_date, slot, status, photo_id, engine, late_upload, counted, captured_at, record_group_id)
    values (q.id, q.challenge_id, v_date, v_slot, 'captured', p_photo, v_engine, v_late, v_qcounted, p_now, v_meal)
    returning id into v_copy;
    if v_late then
      perform raise_flag(q.id, v_date, 'late_upload', jsonb_build_object('key', v_copy::text, 'meal_id', v_copy,
        'client_captured_at', ph.client_captured_at, 'server_received_at', p_now, 'counted', v_qcounted), p_now);
    end if;
    if v_dup then
      perform raise_flag(q.id, v_date, 'dup_photo', jsonb_build_object('key', v_copy::text, 'meal_id', v_copy, 'photo_id', p_photo), p_now);
    end if;
    if v_qcounted then perform recompute_day(q.id, v_date); end if;
  end loop;

  return jsonb_build_object('meal_id', v_meal, 'status', 'captured', 'local_date', v_date, 'slot', v_slot, 'engine', v_engine,
    'late_upload', v_late, 'counted', v_counted, 'dup_photo', v_dup, 'analyze', v_engine <> 'none' and v_counted);
end $$;

-- ---------------------------------------------------------------- 식사 확정 (API #12)
-- 기록 공유(D52): 대표 끼니를 확정하면 복사본도 같은 항목으로 확정한다(그 챌린지 규칙·수정 기한으로, 안 되면 건너뜀).
-- 복사본 실패는 대표를 막지 않는다. 대표가 unchanged 로 돌아갈 때도 호출하므로, 같은 내용 재전송이 실패한 복사본을 복구한다.
-- 이미 같은 값인 복사본은 자기 confirm_meal 에서 unchanged 로 끝나 멱등이다.
create or replace function confirm_meal_copies(p_user uuid, p_meal meals, p_items jsonb, p_now timestamptz)
  returns void language plpgsql as $$
declare c meals;
begin
  if p_meal.id is distinct from p_meal.record_group_id then return; end if;
  for c in select * from meals where record_group_id = p_meal.id and id <> p_meal.id and status not in ('void', 'skipped')
  loop
    begin
      perform confirm_meal(p_user, c.id, p_items, c.version, p_now);
    exception when others then
      raise notice 'group copy % not confirmed: %', c.id, sqlerrm;
    end;
  end loop;
end $$;

-- 원본(20261001000300_batch.sql)에 기록 공유(D52) 한 군데만 더했다: 확정 후·unchanged 반환 전 confirm_meal_copies 호출.
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
    broth_off, bite_fraction, eaten, confidence, ai_kcal, confirmed_kcal)
  select m.id, coalesce(array(select jsonb_array_elements_text(x -> 'name_candidates')), '{}'), x ->> 'chosen_name', x ->> 'food_code',
    coalesce((x ->> 'input_type')::meal_input_type, 'ai'), coalesce((x ->> 'count')::int, 1), (x ->> 'portion_bucket')::portion_bucket,
    coalesce((x ->> 'portion_multiplier')::numeric, 1), coalesce((x ->> 'broth_off')::boolean, false),
    coalesce((x ->> 'bite_fraction')::numeric, 1), coalesce((x ->> 'eaten')::boolean, true), (x ->> 'confidence')::confidence_level,
    (x ->> 'ai_kcal')::numeric,
    meal_item_kcal(coalesce((x ->> 'serving_kcal')::numeric, (select kcal from food_db_cache f where f.food_code = x ->> 'food_code')),
      coalesce((x ->> 'portion_multiplier')::numeric, 1), coalesce((x ->> 'count')::int, 1), coalesce((x ->> 'broth_off')::boolean, false),
      coalesce((x ->> 'bite_fraction')::numeric, 1), r)
  from jsonb_array_elements(coalesce(p_items, '[]')) x;

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


-- 건너뜀 (API #13): 슬롯에 끼니가 없거나 확정 전일 때만. 남은 주간 횟수 반환.
create or replace function skip_meal(p_user uuid, p_participant uuid, p_date date, p_slot meal_slot, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  p participants; r challenge_rules; v_used int; v_today_used int; v_id uuid; q participants; qch challenges;
begin
  select * into p from participants where id = p_participant;
  if p.user_id is distinct from p_user then raise exception 'forbidden' using errcode = 'PT403'; end if;
  if p_slot = 'snack' then raise exception 'snack cannot be skipped' using errcode = 'PT422'; end if;
  if exists (select 1 from daily_scores where participant_id = p_participant and local_date = p_date and is_final) then
    raise exception 'day already final' using errcode = 'PT422';
  end if;
  r := engine_rules(p.challenge_id);
  insert into meals (participant_id, challenge_id, local_date, slot, status, engine)
  values (p_participant, p.challenge_id, p_date, p_slot, 'skipped', 'none')
  on conflict (participant_id, local_date, slot) where status = 'skipped' do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from meals where participant_id = p_participant and local_date = p_date and slot = p_slot and status = 'skipped';
  end if;
  v_used := skips_used_before(p_participant, p_date, r);
  select count(*) into v_today_used from meals where participant_id = p_participant and local_date = p_date and status = 'skipped';
  perform recompute_day(p_participant, p_date);

  -- 기록 공유(D52): 참가 중인 다른 챌린지에도 같은 건너뜀(기간 안·확정 전 날짜만)
  for q in select * from active_participations(p_user) where id <> p_participant
  loop
    select * into qch from challenges where id = q.challenge_id;
    continue when p_date < qch.start_date or p_date > qch.end_date or p_date < q.check_start
      or exists (select 1 from daily_scores where participant_id = q.id and local_date = p_date and is_final);
    insert into meals (participant_id, challenge_id, local_date, slot, status, engine, record_group_id)
    values (q.id, q.challenge_id, p_date, p_slot, 'skipped', 'none', v_id)
    on conflict (participant_id, local_date, slot) where status = 'skipped' do nothing;
    perform recompute_day(q.id, p_date);
  end loop;

  return jsonb_build_object('meal_id', v_id, 'remaining_week', greatest(0, r.skip_per_week - v_used - least(v_today_used, r.skip_per_day)),
    'over_limit', v_today_used > r.skip_per_day or v_used + v_today_used > r.skip_per_week);
end $$;

-- ---------------------------------------------------------------- 직접 입력 끼니 (API #10)
-- 사진 없는 확정 끼니. items 형식은 confirm_meal 과 같다. 하루 3건 이상 → manual_input_burst 플래그(값 유지)
create or replace function create_manual_meal(p_user uuid, p_slot meal_slot, p_items jsonb, p_local_date date default null,
  p_now timestamptz default now()) returns jsonb
  language plpgsql as $$
declare p participants; ch challenges; v_date date := coalesce(p_local_date, kst_date(p_now)); v_meal uuid; r jsonb; v_n int;
  q participants; qch challenges;
begin
  p := active_participant(p_user);
  if p.id is null then raise exception '진행 중인 챌린지가 없어요' using errcode = 'PT403'; end if;
  select * into ch from challenges where id = p.challenge_id;
  if v_date > kst_date(p_now) or v_date < kst_date(p_now) - 2 or v_date < ch.start_date or v_date > ch.end_date then
    raise exception '오늘부터 이틀 전까지만 입력할 수 있어요' using errcode = 'PT422';
  end if;
  if exists (select 1 from daily_scores where participant_id = p.id and local_date = v_date and is_final) then
    raise exception '확정된 날짜예요' using errcode = 'PT422';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'items 가 비었어요' using errcode = 'PT422'; end if;
  insert into meals (participant_id, challenge_id, local_date, slot, status, engine, captured_at)
  values (p.id, p.challenge_id, v_date, p_slot, 'captured', 'none', p_now) returning id into v_meal;
  -- 기록 공유(D52): 복사본을 먼저 만들고, 대표 확정(confirm_meal)이 복사본까지 확정한다
  for q in select * from active_participations(p_user) where id <> p.id
  loop
    select * into qch from challenges where id = q.challenge_id;
    continue when v_date < qch.start_date or v_date > qch.end_date or v_date < q.check_start
      or exists (select 1 from daily_scores where participant_id = q.id and local_date = v_date and is_final);
    insert into meals (participant_id, challenge_id, local_date, slot, status, engine, captured_at, record_group_id)
    values (q.id, q.challenge_id, v_date, p_slot, 'captured', 'none', p_now, v_meal);
  end loop;
  r := confirm_meal(p_user, v_meal,
    (select jsonb_agg(x || jsonb_build_object('input_type', coalesce(x ->> 'input_type', 'manual'))) from jsonb_array_elements(p_items) x),
    1, p_now);
  select count(*) into v_n from meals m where m.participant_id = p.id and m.local_date = v_date and m.photo_id is null
    and m.status in ('confirmed', 'corrected');
  if v_n >= 3 then
    perform raise_flag(p.id, v_date, 'manual_input_burst', jsonb_build_object('key', v_date::text, 'count', v_n), p_now);
  end if;
  return r || jsonb_build_object('local_date', v_date, 'slot', p_slot, 'manual_count_today', v_n);
end $$;

revoke execute on function active_participations(uuid, challenge_status[]), meals_group_default(), meals_group_sync(),
  confirm_meal_copies(uuid, meals, jsonb, timestamptz)
  from public, anon, authenticated;
grant execute on function active_participations(uuid, challenge_status[]), confirm_meal_copies(uuid, meals, jsonb, timestamptz) to service_role;
