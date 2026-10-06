-- 걸음 출처 신뢰(D72): 휴대폰 자체 센서 기록(Health Connect 가 'com.android.healthconnect.phone.<기기값>' 으로 표시)을 믿는 출처로.
-- 허용 목록(origin_whitelist)에서 '.' 으로 끝나는 항목은 앞부분 일치, 그 밖은 지금처럼 정확히 일치.
-- 미확인 출처 검토(source_unknown)에는 출처별 걸음 수·첫/마지막 기록 시각을 남겨 사용자·운영자가 어떤 기록인지 볼 수 있게 한다.

create or replace function origin_trusted(p_origin text, p_whitelist text[]) returns boolean
  language sql immutable as $fn$
  select p_origin is not null and exists (
    select 1 from unnest(coalesce(p_whitelist, '{}')) w
    where p_origin = w or (right(w, 1) = '.' and starts_with(p_origin, w)))
$fn$;
grant execute on function origin_trusted(text, text[]) to authenticated, service_role;

alter table challenge_rules alter column origin_whitelist set default array[
  'com.apple.health', 'com.sec.android.app.shealth', 'android', 'com.google.android.apps.healthdata',
  'com.garmin.android.apps.connectmobile', 'com.fitbit.FitbitMobile', 'com.huami.watch.hmwatchmanager', 'com.xiaomi.wearable',
  'com.android.healthconnect.phone.'];
update challenge_rules set origin_whitelist = array_append(origin_whitelist, 'com.android.healthconnect.phone.')
  where not ('com.android.healthconnect.phone.' = any (origin_whitelist));

-- 원래 정의(20261001000300_batch.sql 의 ingest_activity_batch, 20261003000700 에서 ingest_activity_one 으로 이름만 바뀜)에서
-- 출처 판정을 origin_trusted 로, 검토 target 에 걸음 수·시각을 더한 것만 바꿨다.
create or replace function ingest_activity_one(p_participant uuid, p_batch jsonb, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  p participants;
  ch challenges;
  r challenge_rules;
  v_existing sync_batches;
  v_hash text := md5(p_batch::text);
  v_today date := kst_date(p_now);
  day jsonb; s jsonb; src jsonb;
  v_date date;
  v_out jsonb := '[]';
  v_score daily_scores;
  v_final boolean;
  v_verified int;
  v_start timestamptz; v_end timestamptz; v_part_start timestamptz; v_part_end timestamptz;
  v_d date; v_frac numeric; v_min numeric; v_speed numeric;
  v_unknown boolean;
  v_result jsonb;
begin
  select * into p from participants where id = p_participant;
  if not found then raise exception 'participant not found' using errcode = 'PT403'; end if;
  select * into ch from challenges where id = p.challenge_id;
  r := engine_rules(ch.id);

  select * into v_existing from sync_batches where client_batch_id = (p_batch ->> 'client_batch_id')::uuid;
  if found then
    if v_existing.participant_id <> p_participant or v_existing.request_hash <> v_hash then
      raise exception 'client_batch_id reused with different body' using errcode = 'PT409';
    end if;
    return v_existing.result || jsonb_build_object('replayed', true);
  end if;

  for day in select * from jsonb_array_elements(coalesce(p_batch -> 'days', '[]'))
  loop
    v_date := (day ->> 'local_date')::date;
    -- 3일 윈도·챌린지 기간 밖·미래 날짜 거부
    if v_date > v_today or v_date < v_today - 2 or v_date < ch.start_date or v_date > ch.end_date then
      v_out := v_out || jsonb_build_object('local_date', v_date, 'rejected', 'out_of_window');
      continue;
    end if;
    select is_final into v_final from daily_scores where participant_id = p_participant and local_date = v_date;
    if coalesce(v_final, false) then
      -- 확정 뒤 도착: late_delta 에만 기록, 자동 반영 없음(04 T18)
      update daily_activity set late_delta = jsonb_build_object('received_at', p_now, 'day', day)
      where participant_id = p_participant and local_date = v_date;
      v_out := v_out || jsonb_build_object('local_date', v_date, 'late', true);
      continue;
    end if;

    insert into daily_activity as a (participant_id, challenge_id, local_date, steps_total, steps_manual, has_manual_source,
      distance_m, floors, platform_active_kcal, sources, synced_at)
    values (p_participant, p.challenge_id, v_date, coalesce((day ->> 'steps_total')::int, 0), (day ->> 'steps_manual')::int,
      coalesce((day ->> 'has_manual_source')::boolean, false), (day ->> 'distance_m')::numeric, (day ->> 'floors')::int,
      (day ->> 'platform_active_kcal')::numeric, coalesce(day -> 'sources', '[]'), p_now)
    on conflict (participant_id, local_date) do update set
      steps_total = excluded.steps_total, steps_manual = excluded.steps_manual, has_manual_source = excluded.has_manual_source,
      distance_m = excluded.distance_m, floors = excluded.floors, platform_active_kcal = excluded.platform_active_kcal,
      sources = excluded.sources, synced_at = excluded.synced_at;

    -- 세션: 자정 분할 → upsert (platform_uid, local_date)
    for s in select * from jsonb_array_elements(coalesce(day -> 'sessions', '[]'))
    loop
      v_start := (s ->> 'start')::timestamptz; v_end := (s ->> 'end')::timestamptz;
      continue when v_end <= v_start;
      for v_d in select generate_series(kst_date(v_start), kst_date(v_end - interval '1 microsecond'), '1 day')::date
      loop
        v_part_start := greatest(v_start, kst_at(v_d, '00:00'));
        v_part_end := least(v_end, kst_at(v_d + 1, '00:00'));
        v_frac := extract(epoch from (v_part_end - v_part_start)) / extract(epoch from (v_end - v_start));
        continue when v_d < v_today - 2 or v_d > v_today or v_d < ch.start_date or v_d > ch.end_date;
        -- 확정된 날짜의 분할분은 넣지 않는다(late_delta 원칙, 04 T18)
        continue when exists (select 1 from daily_scores where participant_id = p_participant and local_date = v_d and is_final);
        v_min := extract(epoch from (v_part_end - v_part_start)) / 60;
        v_speed := case when (s ->> 'distance_m') is not null and v_min > 0 then (s ->> 'distance_m')::numeric * v_frac * 60 / (v_min * 1000) end;
        insert into activity_sessions as x (participant_id, challenge_id, local_date, platform_uid, type, start_at, end_at,
          steps_in_range, distance_m, avg_speed_kmh, met, origin, recording_method, is_counted, excluded_reason)
        values (p_participant, p.challenge_id, v_d, s ->> 'platform_uid', (s ->> 'type')::session_type, v_part_start, v_part_end,
          round(coalesce((s ->> 'steps_in_range')::numeric, 0) * v_frac)::int, (s ->> 'distance_m')::numeric * v_frac, v_speed,
          session_met(s ->> 'type', v_min, (s ->> 'distance_m')::numeric * v_frac, r), s ->> 'origin', s ->> 'method',
          upper(coalesce(s ->> 'method', '')) <> 'MANUAL_ENTRY',
          case when upper(coalesce(s ->> 'method', '')) = 'MANUAL_ENTRY' then 'manual' end)
        on conflict (participant_id, platform_uid, local_date) do update set
          type = excluded.type, start_at = excluded.start_at, end_at = excluded.end_at, steps_in_range = excluded.steps_in_range,
          distance_m = excluded.distance_m, avg_speed_kmh = excluded.avg_speed_kmh, met = excluded.met, origin = excluded.origin,
          recording_method = excluded.recording_method,
          is_counted = case when x.excluded_reason in ('verdict') then false else excluded.is_counted end,
          excluded_reason = case when x.excluded_reason in ('verdict') then x.excluded_reason else excluded.excluded_reason end,
          merged_into_id = null;
        -- 세션 이상치(5분 미만·6시간 초과·>25 km/h): 값 유지 + 플래그
        if v_min < 5 or v_min > 360 or coalesce(v_speed, 0) > 25 then
          perform raise_flag(p_participant, v_d, 'session_anomaly', jsonb_build_object('key', s ->> 'platform_uid'), p_now);
        end if;
      end loop;
    end loop;
  end loop;

  -- 폰+워치 겹치는 세션 병합: 겹치면 긴 세션 1건만 is_counted (04 T06)
  update activity_sessions short set is_counted = false, merged_into_id = long.id, excluded_reason = 'merged'
  from activity_sessions long
  where short.participant_id = p_participant and long.participant_id = p_participant
    and short.local_date = long.local_date and short.local_date >= v_today - 2
    and short.id <> long.id and short.type <> 'walking' and long.type <> 'walking'
    and short.is_counted and long.is_counted
    and short.start_at < long.end_at and long.start_at < short.end_at
    and ((long.end_at - long.start_at) > (short.end_at - short.start_at)
      or ((long.end_at - long.start_at) = (short.end_at - short.start_at) and long.id < short.id));

  -- 점수 재계산 + 플래그
  for day in select * from jsonb_array_elements(coalesce(p_batch -> 'days', '[]'))
  loop
    v_date := (day ->> 'local_date')::date;
    continue when v_date > v_today or v_date < v_today - 2 or v_date < ch.start_date or v_date > ch.end_date;
    select is_final into v_final from daily_scores where participant_id = p_participant and local_date = v_date;
    continue when coalesce(v_final, false);

    v_verified := greatest(0, coalesce((day ->> 'steps_total')::int, 0) - coalesce((day ->> 'steps_manual')::int, 0));
    if v_verified > r.steps_spike_abs
      or (p.baseline_median_steps is not null and v_verified > p.baseline_median_steps * r.steps_spike_ratio) then
      perform raise_flag(p_participant, v_date, 'steps_spike', jsonb_build_object('key', v_date::text, 'steps', v_verified), p_now);
    end if;
    v_unknown := false;
    for src in select * from jsonb_array_elements(coalesce(day -> 'sources', '[]'))
    loop
      if not origin_trusted(src ->> 'origin', r.origin_whitelist) then
        -- 검토 상세에 그 출처의 걸음 수·첫/마지막 기록 시각(앱이 보내면, D72)
        perform raise_flag(p_participant, v_date, 'source_unknown', jsonb_build_object('key', src ->> 'origin', 'origin', src ->> 'origin')
          || jsonb_strip_nulls(jsonb_build_object('steps', src -> 'steps', 'first_at', src -> 'first_at', 'last_at', src -> 'last_at')), p_now);
      end if;
    end loop;
    for s in select * from jsonb_array_elements(coalesce(day -> 'sessions', '[]'))
    loop
      if s ->> 'origin' is not null and not origin_trusted(s ->> 'origin', r.origin_whitelist) then
        perform raise_flag(p_participant, v_date, 'source_unknown', jsonb_build_object('key', s ->> 'origin', 'origin', s ->> 'origin')
          || jsonb_strip_nulls(jsonb_build_object('steps', s -> 'steps_in_range', 'first_at', s -> 'start', 'last_at', s -> 'end')), p_now);
      end if;
    end loop;
    if coalesce((day ->> 'has_manual_source')::boolean, false) and (day ->> 'steps_manual') is null then
      -- Android: 수동 출처 감지 → 숫자 대신 플래그(04 §3.1)
      perform raise_flag(p_participant, v_date, 'source_unknown', jsonb_build_object('key', 'manual_source', 'origin', 'manual'), p_now);
    end if;

    v_score := compute_daily_score(p_participant, v_date, 'provisional');
    v_out := v_out || jsonb_build_object('local_date', v_date, 'a_d', v_score.a_d, 's_d', v_score.s_d, 'under_review', v_score.under_review);
  end loop;

  update participants set last_synced_at = p_now,
    last_sync_source = coalesce((p_batch #>> '{days,0,sources,0,origin}'), last_sync_source)
  where id = p_participant;

  v_result := jsonb_build_object('days', v_out);
  insert into sync_batches (participant_id, client_batch_id, request_hash, result)
  values (p_participant, (p_batch ->> 'client_batch_id')::uuid, v_hash, v_result);
  return v_result;
end $$;
