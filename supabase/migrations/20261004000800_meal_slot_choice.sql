-- 촬영 화면에서 고른 끼니(아침·점심·저녁·간식)로 저장한다(D58, D55 확장). 고르지 않으면 지금처럼 서버 시각 슬롯.
-- 서버 시각 슬롯은 meals.time_slot 에 남겨, 운영자가 고른 끼니와 촬영 시각이 다른 기록을 볼 수 있게 한다.

alter table meals add column time_slot meal_slot;
comment on column meals.time_slot is '촬영(태그) 시각 기준 슬롯. slot 은 사용자가 고른 끼니(D58)';

-- ---------------------------------------------------------------- 사진 끼니 만들기 (API #9)
-- 원본(20261004000200_snack_choice.sql)에서 바꾼 것: 끝 인자 p_slot, time_slot 저장. p_snack 은 배포 사이 옛 Edge 호환으로 남긴다.
-- 인자를 더하면 오버로드가 생겨 PostgREST 이름 호출이 모호해지므로 옛 5인자 함수를 지우고 새로 만든다.
drop function create_meal(uuid, uuid, boolean, timestamptz, boolean);
create function create_meal(p_user uuid, p_photo uuid, p_queued boolean default false, p_now timestamptz default now(),
  p_snack boolean default false, p_slot meal_slot default null)
  returns jsonb language plpgsql as $$
declare
  ph photos; p participants; ch challenges; r challenge_rules;
  v_tag_at timestamptz := p_now;
  v_diff interval;
  v_late boolean := false;
  v_counted boolean := true;
  v_date date; v_slot meal_slot; v_time_slot meal_slot;
  v_engine ai_engine := 'none';
  v_meal uuid;
  v_dup boolean;
  q participants; qch challenges; v_copy uuid; v_qcounted boolean;
  v_alt participants;
begin
  select * into ph from photos where id = p_photo;
  if not found then raise exception 'photo not found' using errcode = 'PT404'; end if;
  select * into p from participants where id = ph.participant_id;
  if p.user_id is distinct from p_user then raise exception 'not your photo' using errcode = 'PT403'; end if;
  if ph.verified_at is null then raise exception '사진 업로드 확인 전이에요' using errcode = 'PT422'; end if;
  if exists (select 1 from meals m join participants x on x.id = m.participant_id
             where m.photo_id = p_photo and m.record_group_id = m.id and x.user_id = p_user) then
    return (select jsonb_build_object('meal_id', m.id, 'status', m.status, 'local_date', m.local_date, 'slot', m.slot, 'replayed', true)
      from meals m join participants x on x.id = m.participant_id
      where m.photo_id = p_photo and m.record_group_id = m.id and x.user_id = p_user
      order by m.captured_at limit 1);
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
  -- 겹치는 챌린지 경계(F2): 사진 주인 참가가 이 날짜를 품지 않으면, 품는 참가 중 가장 최근 것을 대표로
  if v_date < ch.start_date or v_date > ch.end_date or v_date < p.check_start then
    select x.* into v_alt from active_participations(p_user) x join challenges c on c.id = x.challenge_id
    where v_date between c.start_date and c.end_date and x.check_start <= v_date
    order by x.joined_at desc limit 1;
    if v_alt.id is not null then
      p := v_alt;
      select * into ch from challenges where id = p.challenge_id;
      r := engine_rules(ch.id);
    end if;
  end if;
  v_time_slot := slot_for(v_tag_at, r);
  -- 촬영 화면에서 고른 끼니(D58). 고르지 않았으면 서버 시각 슬롯. p_snack 은 옛 Edge 호출 호환(D55).
  v_slot := coalesce(p_slot, case when p_snack then 'snack'::meal_slot end, v_time_slot);
  if v_counted and (v_date < ch.start_date or v_date > ch.end_date) then
    raise exception '챌린지 기간 밖의 사진이에요' using errcode = 'PT422';
  end if;
  if v_counted and exists (select 1 from daily_scores where participant_id = p.id and local_date = v_date and is_final) then
    v_counted := false; -- 확정된 날짜로 태그되는 경우(서버 시각 기준)도 미인정
  end if;
  if exists (select 1 from consents where user_id = p_user and type = 'overseas_ai' and revoked_at is null) then
    v_engine := 'gemini';
  end if;

  insert into meals (participant_id, challenge_id, local_date, slot, time_slot, status, photo_id, engine, late_upload, counted, captured_at)
  values (p.id, p.challenge_id, v_date, v_slot, v_time_slot, 'captured', p_photo, v_engine, v_late, v_counted, p_now)
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
    insert into meals (participant_id, challenge_id, local_date, slot, time_slot, status, photo_id, engine, late_upload, counted, captured_at,
      record_group_id)
    values (q.id, q.challenge_id, v_date, v_slot, v_time_slot, 'captured', p_photo, v_engine, v_late, v_qcounted, p_now, v_meal)
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

revoke execute on function create_meal(uuid, uuid, boolean, timestamptz, boolean, meal_slot) from public, anon, authenticated;
grant execute on function create_meal(uuid, uuid, boolean, timestamptz, boolean, meal_slot) to service_role;
