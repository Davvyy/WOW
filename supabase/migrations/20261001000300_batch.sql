-- 점수 배치·동기화·판정 (docs/05 §5·§6·§7, docs/04 §5.4·§7)
-- 모든 점수는 compute_daily_score → activity_kcal / intake_kcal / score_simulate 경로 하나로만 계산한다.
-- PostgREST 오류 매핑: SQLSTATE 'PTnnn' → HTTP nnn (PT403·PT409·PT412·PT422).

-- ---------------------------------------------------------------- 시간 헬퍼
create or replace function kst_date(p_ts timestamptz default now()) returns date
  language sql stable as $$ select (p_ts at time zone 'Asia/Seoul')::date $$;

create or replace function kst_at(p_date date, p_time time) returns timestamptz
  language sql immutable as $$ select (p_date + p_time) at time zone 'Asia/Seoul' $$;

-- 챌린지 일차(시작일=1)
create or replace function challenge_day_index(p_challenge challenges, p_date date) returns int
  language sql immutable as $$ select (p_date - p_challenge.start_date) + 1 $$;

-- ---------------------------------------------------------------- 알림 큐 (03 §8)
-- transactional(N-04·N-06): 즉시. scheduled(N-01·02·03·05·07): 22:00~08:00 생성분은 다음 08:00.
create or replace function enqueue_notification(p_user uuid, p_challenge uuid, p_type notification_type,
  p_title text, p_body text, p_payload jsonb default '{}', p_now timestamptz default now()) returns uuid
  language plpgsql as $$
declare
  v_cat notification_category := case when p_type in ('N-04', 'N-06') then 'transactional' else 'scheduled' end;
  v_local timestamp := p_now at time zone 'Asia/Seoul';
  v_at timestamptz := p_now;
  v_id uuid;
begin
  if p_user is null then return null; end if;
  if v_cat = 'scheduled' then
    if v_local::time >= '22:00' then v_at := kst_at(v_local::date + 1, '08:00');
    elsif v_local::time < '08:00' then v_at := kst_at(v_local::date, '08:00');
    end if;
  end if;
  insert into notifications (user_id, challenge_id, type, category, title, body, payload, scheduled_at)
  values (p_user, p_challenge, p_type, v_cat, p_title, p_body, p_payload, v_at)
  returning id into v_id;
  return v_id;
end $$;

-- 발송 워커(Edge Function notify)가 호출: 보낼 알림을 집어 sent_at 표시 후 돌려준다.
-- 푸시 토큰 없음·권한 미허용 → skipped_reason='no_push'(앱 인앱 배너로 대체), scheduled 하루 4건 초과 → 'daily_cap'.
create or replace function claim_due_notifications(p_now timestamptz default now(), p_limit int default 200)
  returns table (id uuid, user_id uuid, type notification_type, title text, body text, payload jsonb, push_tokens text[])
  language plpgsql as $$
declare
  n record;
  v_tokens text[];
  v_sent_today int;
begin
  for n in
    select x.* from notifications x
    where x.sent_at is null and x.skipped_reason is null and x.scheduled_at <= p_now
    order by x.scheduled_at
    limit p_limit
    for update skip locked
  loop
    select array_agg(d.push_token) into v_tokens from devices d
      where d.user_id = n.user_id and d.push_permission = 'granted' and d.push_token is not null;
    if v_tokens is null then
      update notifications set skipped_reason = 'no_push' where notifications.id = n.id;
      continue;
    end if;
    if n.category = 'scheduled' then
      select count(*) into v_sent_today from notifications s
        where s.user_id = n.user_id and s.category = 'scheduled' and s.sent_at is not null
          and kst_date(s.sent_at) = kst_date(p_now);
      if v_sent_today >= 4 then
        update notifications set skipped_reason = 'daily_cap' where notifications.id = n.id;
        continue;
      end if;
    end if;
    update notifications set sent_at = p_now where notifications.id = n.id;
    id := n.id; user_id := n.user_id; type := n.type; title := n.title; body := n.body; payload := n.payload; push_tokens := v_tokens;
    return next;
  end loop;
end $$;

-- ---------------------------------------------------------------- 감사 로그
create or replace function write_audit(p_challenge uuid, p_actor uuid, p_role text, p_action text, p_target jsonb,
  p_before jsonb default null, p_after jsonb default null) returns void
  language sql as $$
  insert into audit_logs (challenge_id, actor_id, actor_role, action, target, before, after)
  values (p_challenge, p_actor, p_role, p_action, coalesce(p_target, '{}'), p_before, p_after)
$$;

-- ---------------------------------------------------------------- 건너뜀 주간 사용량
-- 같은 주(월~일, KST) 이전 날짜에서 인정된 건너뜀 수. 하루 최대 skip_per_day 만 인정.
create or replace function skips_used_before(p_participant uuid, p_date date, p_rules challenge_rules) returns int
  language sql stable as $$
  select least(p_rules.skip_per_week, coalesce(sum(least(cnt, p_rules.skip_per_day)), 0))::int
  from (
    select local_date, count(*) cnt from meals
    where participant_id = p_participant and status = 'skipped' and slot <> 'snack'
      and local_date >= date_trunc('week', p_date)::date and local_date < p_date
    group by local_date
  ) x
$$;

-- ---------------------------------------------------------------- 일 점수 계산 (단일 경로)
-- p_mode: 'provisional' 매시 잠정(확정된 날은 건드리지 않음)
--         'finalize'    D+1 09:00 확정: 초안 → 자동 확정(max(M, 1.3×AI)) 후 is_final
--         'revise'      확정 후 정정(사용자 48h 수정·운영자 판정·지연 반영) → score_revisions
create or replace function compute_daily_score(p_participant uuid, p_date date, p_mode text default 'provisional',
  p_reason revision_reason default null, p_review_id uuid default null, p_actor uuid default null)
  returns daily_scores language plpgsql as $$
declare
  p participants;
  ch challenges;
  r challenge_rules;
  da daily_activity;
  prev daily_scores;
  res daily_scores;
  v_sessions jsonb;
  v_session_steps int;
  v_steps_total int;
  v_meals jsonb;
  v_skips int;
  a jsonb; i jsonb; s jsonb;
  v_m numeric;
  v_under_review boolean;
  v_is_final boolean;
begin
  select * into p from participants where id = p_participant;
  if not found then raise exception 'participant % not found', p_participant using errcode = 'P0002'; end if;
  select * into ch from challenges where id = p.challenge_id;
  r := engine_rules(p.challenge_id);
  select * into prev from daily_scores where participant_id = p_participant and local_date = p_date;

  if p_mode = 'provisional' and prev.is_final then
    return prev; -- 확정 뒤에는 정정 경로로만 바뀐다(04 §5.4)
  end if;

  v_m := m_p(p.bmr_locked, r);
  if p_mode = 'finalize' then
    -- 04 §4.3 미확정 AI 초안 자동 확정
    update meals set status = 'auto', confirmed_kcal = greatest(v_m, r.auto_confirm * coalesce(ai_kcal, 0)),
      delta_ratio = case when ai_kcal > 0 then greatest(v_m, r.auto_confirm * ai_kcal) / ai_kcal end, confirmed_at = now()
    where participant_id = p_participant and local_date = p_date and status = 'draft' and counted;
  end if;

  -- 활동 입력
  select * into da from daily_activity where participant_id = p_participant and local_date = p_date;
  select coalesce(jsonb_agg(jsonb_build_object(
      'type', s.type, 'minutes', extract(epoch from (s.end_at - s.start_at)) / 60,
      'distance_m', s.distance_m, 'steps_in_range', s.steps_in_range)), '[]'),
    coalesce(sum(s.steps_in_range) filter (where s.type <> 'walking'), 0)
  into v_sessions, v_session_steps
  from activity_sessions s
  where s.participant_id = p_participant and s.local_date = p_date and s.is_counted
    and upper(coalesce(s.recording_method, '')) <> 'MANUAL_ENTRY';
  -- 검증 걸음 = 합계 − 수동(iOS) − 판정 제외분. steps_spike 무효 판정은 세션 밖 걸음을 기준선으로 대체.
  v_steps_total := greatest(0, coalesce(da.steps_total, 0) - coalesce(da.steps_manual, 0) - coalesce(da.steps_excluded, 0));
  if da.steps_out_override is not null then
    v_steps_total := da.steps_out_override + v_session_steps;
  end if;
  a := activity_kcal(p.weight_locked, v_steps_total, v_sessions, coalesce(da.floors, 0), r);

  -- 섭취 입력(counted=false 지연 업로드 끼니는 제외)
  select coalesce(jsonb_agg(jsonb_build_object('slot', m.slot, 'status', m.status, 'kcal', m.confirmed_kcal, 'ai_kcal', m.ai_kcal)), '[]')
  into v_meals from meals m where m.participant_id = p_participant and m.local_date = p_date and m.counted;
  v_skips := skips_used_before(p_participant, p_date, r);
  i := intake_kcal(p.bmr_locked, v_meals, v_skips, r);
  s := score_simulate(p.bmr_locked, (a ->> 'a_d')::numeric, (i ->> 'i_d')::numeric, (i ->> 'main_meal_count')::int, r);

  select exists (select 1 from reviews rv where rv.participant_id = p_participant and rv.local_date = p_date
    and rv.status in ('open', 'appealed') and rv.type not in ('session_anomaly', 'manual_input_burst', 'late_upload', 'photo_mismatch'))
  into v_under_review;
  v_is_final := coalesce(prev.is_final, false) or p_mode = 'finalize';

  if da.id is not null then
    update daily_activity set steps_in_sessions = v_session_steps,
      steps_net_kcal = (a ->> 'steps_net_kcal')::numeric, sessions_net_kcal = (a ->> 'sessions_net_kcal')::numeric,
      floors_kcal = (a ->> 'floors_kcal')::numeric, a_raw = (a ->> 'a_raw')::numeric, a_capped = (a ->> 'a_d')::numeric
    where id = da.id;
  end if;

  insert into daily_scores as d (participant_id, challenge_id, local_date, bmr, a_d, i_confirmed, i_snack, substitute_slots, m_p,
    i_d, f_p, d_d, s_d, main_meal_count, is_counted, is_final, finalized_at, under_review, breakdown, computed_at)
  values (p_participant, p.challenge_id, p_date, p.bmr_locked, (a ->> 'a_d')::numeric, (i ->> 'i_confirmed')::numeric,
    (i ->> 'i_snack')::numeric, jsonb_array_length(i -> 'substitute_slots') + jsonb_array_length(i -> 'pending_slots'),
    v_m, (i ->> 'i_d')::numeric, (s ->> 'f_p')::numeric, (s ->> 'd_d')::numeric, (s ->> 's_d')::numeric,
    (i ->> 'main_meal_count')::int,
    challenge_day_index(ch, p_date) > r.check_days,
    v_is_final, case when p_mode = 'finalize' then now() else prev.finalized_at end,
    v_under_review,
    jsonb_build_object('activity', a, 'intake', i, 'score', s,
      'inputs', jsonb_build_object('steps_total', da.steps_total, 'steps_manual', da.steps_manual, 'steps_excluded', da.steps_excluded,
        'steps_out_override', da.steps_out_override, 'steps_verified', v_steps_total, 'floors', da.floors,
        'sessions', v_sessions, 'meals', v_meals, 'skips_used_this_week', v_skips, 'platform_active_kcal', da.platform_active_kcal)),
    now())
  on conflict (participant_id, local_date) do update set
    bmr = excluded.bmr, a_d = excluded.a_d, i_confirmed = excluded.i_confirmed, i_snack = excluded.i_snack,
    substitute_slots = excluded.substitute_slots, m_p = excluded.m_p, i_d = excluded.i_d, f_p = excluded.f_p,
    d_d = excluded.d_d, s_d = excluded.s_d, main_meal_count = excluded.main_meal_count, is_counted = excluded.is_counted,
    is_final = excluded.is_final, finalized_at = excluded.finalized_at, under_review = excluded.under_review,
    breakdown = excluded.breakdown, computed_at = excluded.computed_at
  returning * into res;

  if prev.is_final and p_mode = 'revise' and (prev.s_d is distinct from res.s_d or prev.i_d is distinct from res.i_d or prev.a_d is distinct from res.a_d) then
    insert into score_revisions (daily_score_id, participant_id, prev_s_d, new_s_d, prev_breakdown, reason, review_id, actor_id)
    values (res.id, p_participant, prev.s_d, res.s_d, prev.breakdown, coalesce(p_reason, 'user_edit'), p_review_id, p_actor);
  end if;
  return res;
end $$;

-- 확정 여부에 따라 잠정/정정 경로 선택
create or replace function recompute_day(p_participant uuid, p_date date, p_reason revision_reason default 'user_edit',
  p_review_id uuid default null, p_actor uuid default null) returns daily_scores
  language plpgsql as $$
declare v_final boolean;
begin
  select is_final into v_final from daily_scores where participant_id = p_participant and local_date = p_date;
  return compute_daily_score(p_participant, p_date, case when v_final then 'revise' else 'provisional' end, p_reason, p_review_id, p_actor);
end $$;

-- 누적 = Σ S_d (확정·is_counted)
create or replace function participant_cumulative(p_participant uuid) returns numeric
  language sql stable as $$
  select coalesce(sum(s_d), 0) from daily_scores where participant_id = p_participant and is_counted and is_final
$$;

-- ---------------------------------------------------------------- 리더보드 스냅샷 (05 §7)
-- rows: rank_eligible·leaderboard_visible 참가자만. 검토 중인 행은 타인에게 '집계 중'(이름·점수·id 비공개).
-- 동점 공동 순위 1-2-2-4, 표시 순서 = 점수 → 확정 끼니 수 → 닉네임.
create or replace function build_leaderboard(p_challenge uuid, p_scope leaderboard_scope, p_date date, p_is_final boolean,
  p_as_of timestamptz default now())
  returns uuid language plpgsql as $$
declare v_rows jsonb; v_id uuid;
begin
  with base as (
    select p.id, p.nickname, p.grade_badge, p.grade_badge_public,
      case when p_scope = 'today' then ds.s_d else (select coalesce(sum(x.s_d), 0) from daily_scores x
        where x.participant_id = p.id and x.is_counted and x.is_final and x.local_date <= p_date) end as score,
      case when p_scope = 'today' then coalesce(ds.main_meal_count, 0) else (select coalesce(sum(x.main_meal_count), 0) from daily_scores x
        where x.participant_id = p.id and x.is_counted and x.is_final and x.local_date <= p_date) end as meals,
      exists (select 1 from reviews rv where rv.participant_id = p.id and rv.status in ('open', 'appealed')
        and rv.type not in ('session_anomaly', 'manual_input_burst', 'late_upload', 'photo_mismatch')) as under_review,
      -- 반영률 4칸: 아침·점심·저녁 확정 + 활동 동기화(표시 전용, 05 §5.3)
      (select count(*) from (select distinct m.slot from meals m where m.participant_id = p.id and m.local_date = p_date
         and m.slot <> 'snack' and m.counted and m.status in ('confirmed', 'auto', 'corrected') and m.confirmed_kcal >= 150) z)
        + case when exists (select 1 from daily_activity a where a.participant_id = p.id and a.local_date = p_date and a.synced_at is not null) then 1 else 0 end as fill,
      (select count(*) from cheers c where c.to_participant_id = p.id and c.local_date = p_date) as cheer_count
    from participants p
    left join daily_scores ds on ds.participant_id = p.id and ds.local_date = p_date
    where p.challenge_id = p_challenge and p.rank_eligible and p.leaderboard_visible and p.status = 'active'
  ), ranked as (
    select *, rank() over (order by coalesce(score, 0) desc) as rnk,
      row_number() over (order by coalesce(score, 0) desc, meals desc, nickname) as ord
    from base
  ), tied as (
    select *, count(*) over (partition by rnk) > 1 as tie from ranked
  )
  select coalesce(jsonb_agg(case when under_review then
      jsonb_build_object('rank', rnk, 'aggregating', true, 'fill', 0)
    else jsonb_build_object('rank', rnk, 'participant_id', id, 'nickname', nickname, 'score', coalesce(score, 0),
      'fill', fill, 'cheer_count', cheer_count, 'badge', case when grade_badge_public then grade_badge end,
      'tie', tie)
    end order by ord), '[]')
  into v_rows from tied;

  insert into leaderboard_snapshots (challenge_id, scope, local_date, as_of, is_final, rows)
  values (p_challenge, p_scope, p_date, p_as_of, p_is_final, v_rows) returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------- 배치: 매시 잠정 (05 §7 provisional)
create or replace function run_provisional(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare
  ch challenges;
  v_today date := kst_date(p_now);
  d date;
  p record;
  n int := 0;
begin
  for ch in select * from challenges where status in ('checking', 'running', 'closing')
  loop
    for d in select generate_series(greatest(ch.start_date, v_today - 2), least(ch.end_date, v_today), '1 day')::date
    loop
      for p in select id from participants where challenge_id = ch.id and status in ('active', 'record_mode', 'excluded')
      loop
        perform compute_daily_score(p.id, d, 'provisional');
        n := n + 1;
      end loop;
    end loop;
    if v_today between ch.start_date and ch.end_date then
      perform build_leaderboard(ch.id, 'today', v_today, false, p_now);
    end if;
    perform build_leaderboard(ch.id, 'cumulative', least(v_today, ch.end_date), false, p_now);
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- 배치: D+1 09:00 확정 (05 §7 finalize)
create or replace function run_finalize(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare
  ch challenges;
  r challenge_rules;
  d date := kst_date(p_now) - 1;
  p participants;
  res daily_scores;
  n int := 0;
begin
  for ch in select * from challenges where status in ('checking', 'running', 'closing') and d between start_date and end_date
  loop
    r := engine_rules(ch.id);
    for p in select * from participants where challenge_id = ch.id and status in ('active', 'record_mode', 'excluded')
    loop
      if exists (select 1 from daily_scores where participant_id = p.id and local_date = d and is_final) then continue; end if;
      res := compute_daily_score(p.id, d, 'finalize');
      n := n + 1;
      -- 건너뜀 초과 → skip_abuse 플래그(초과분은 이미 M_p, 판정은 경고)
      if (res.breakdown #>> '{intake,skip_over}')::boolean then
        perform raise_flag(p.id, d, 'skip_abuse', jsonb_build_object('key', d::text), p_now);
      end if;
      -- 점검 기간 마지막 날: 기준선 중앙값(steps_spike 콜드스타트)
      if challenge_day_index(ch, d) = r.check_days then
        update participants set baseline_median_steps = (
          select percentile_cont(0.5) within group (order by greatest(0, a.steps_total - coalesce(a.steps_manual, 0)))::int
          from daily_activity a where a.participant_id = p.id and a.local_date between ch.start_date and d)
        where id = p.id;
      end if;
    end loop;
    perform build_leaderboard(ch.id, 'today', d, true, p_now);
    perform build_leaderboard(ch.id, 'cumulative', d, true, p_now);
    -- 마지막 날 확정 → Running→Closing (03 §7)
    if d = ch.end_date and ch.status = 'running' then
      update challenges set status = 'closing' where id = ch.id;
      perform write_audit(ch.id, null, 'system', 'transition', jsonb_build_object('to', 'closing'), null, null);
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- 플래그 (04 §7)
create or replace function raise_flag(p_participant uuid, p_date date, p_type review_type, p_target jsonb, p_now timestamptz default now())
  returns uuid language plpgsql as $$
declare
  p participants;
  v_id uuid;
  v_notify boolean := p_type in ('steps_spike', 'source_unknown', 'dup_photo', 'downward_edit', 'skip_abuse', 'multi_device');
  v_notif uuid;
  v_sched timestamptz;
begin
  select * into p from participants where id = p_participant;
  insert into reviews (challenge_id, participant_id, type, local_date, target, reason_template)
  values (p.challenge_id, p_participant, p_type, p_date, coalesce(p_target, '{}'),
    case when p_type in ('steps_spike', 'source_unknown', 'dup_photo', 'downward_edit', 'skip_abuse') then p_type::text end)
  on conflict (participant_id, type, local_date, coalesce(target ->> 'key', '')) where type not in ('report', 'objection')
  do nothing
  returning id into v_id;
  if v_id is null then return null; end if;

  if v_notify then
    -- N-05 검토 안내·소명 요청. 소명 72h 는 N-05 발송 시각 기산(22~08시 생성분은 08:00 발송)
    v_notif := enqueue_notification(p.user_id, p.challenge_id, 'N-05', '기록 확인 안내',
      '기록을 확인 중이에요. 72시간 안에 설명을 남길 수 있어요', jsonb_build_object('review_id', v_id), p_now);
    select scheduled_at into v_sched from notifications where id = v_notif;
    update reviews set notified_at = coalesce(v_sched, p_now), sla_due_at = coalesce(v_sched, p_now) + interval '72 hours' where id = v_id;
    update daily_scores set under_review = true where participant_id = p_participant and local_date = p_date;
  else
    update reviews set sla_due_at = p_now + interval '72 hours' where id = v_id;
  end if;
  perform write_audit(p.challenge_id, null, 'system', 'flag', jsonb_build_object('review_id', v_id, 'type', p_type, 'local_date', p_date));
  return v_id;
end $$;

-- ---------------------------------------------------------------- 동기화 배치 (05 §5, API #6)
-- Edge Function sync-activity 가 service_role 로 호출. 멱등성: client_batch_id.
create or replace function ingest_activity_batch(p_participant uuid, p_batch jsonb, p_now timestamptz default now())
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
      if not (src ->> 'origin' = any (r.origin_whitelist)) then
        perform raise_flag(p_participant, v_date, 'source_unknown', jsonb_build_object('key', src ->> 'origin', 'origin', src ->> 'origin'), p_now);
      end if;
    end loop;
    for s in select * from jsonb_array_elements(coalesce(day -> 'sessions', '[]'))
    loop
      if s ->> 'origin' is not null and not (s ->> 'origin' = any (r.origin_whitelist)) then
        perform raise_flag(p_participant, v_date, 'source_unknown', jsonb_build_object('key', s ->> 'origin', 'origin', s ->> 'origin'), p_now);
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

-- ---------------------------------------------------------------- 식사 확정 (API #12)
-- p_items: [{chosen_name, food_code?, serving_kcal?, input_type, count, portion_multiplier, broth_off, bite_fraction, eaten,
--            name_candidates?, portion_bucket?, confidence?, ai_kcal?}]
-- 동일 내용 재전송은 revision·플래그 없이 현재 상태를 돌려준다.
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
  return jsonb_build_object('meal_id', m.id, 'confirmed_kcal', v_total, 'delta_ratio', v_ratio, 'version', m.version,
    'status', m.status, 'flags', to_jsonb(v_flags), 's_d', v_score.s_d, 'is_final', v_score.is_final);
end $$;

-- 건너뜀 (API #13): 슬롯에 끼니가 없거나 확정 전일 때만. 남은 주간 횟수 반환.
create or replace function skip_meal(p_user uuid, p_participant uuid, p_date date, p_slot meal_slot, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  p participants; r challenge_rules; v_used int; v_today_used int; v_id uuid;
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
  v_used := skips_used_before(p_participant, p_date, r);
  select count(*) into v_today_used from meals where participant_id = p_participant and local_date = p_date and status = 'skipped';
  perform recompute_day(p_participant, p_date);
  return jsonb_build_object('meal_id', v_id, 'remaining_week', greatest(0, r.skip_per_week - v_used - least(v_today_used, r.skip_per_day)),
    'over_limit', v_today_used > r.skip_per_day or v_used + v_today_used > r.skip_per_week);
end $$;

-- ---------------------------------------------------------------- 판정 (API #28, 04 §7, 06 §6)
create or replace function format_k1(x numeric) returns text language sql immutable as $$
  select to_char(r1(x), 'FM999,990.0')
$$;
create or replace function format_signed1(x numeric) returns text language sql immutable as $$
  select case when x > 0 then '+' when x < 0 then '−' else '±' end || format_k1(abs(x))
$$;
create or replace function format_md(d date) returns text language sql immutable as $$
  select extract(month from d)::int || '.' || extract(day from d)::int
$$;
-- 받침 있으면 '으로', 없으면 '로'(ㄹ 받침 포함 '로'). 숫자 끝자리는 한국어 읽기 기준.
create or replace function josa_ro(word text) returns text language plpgsql immutable as $$
declare c text := right(word, 1); code int;
begin
  if c ~ '[0-9]' then
    return case when c in ('0', '3', '6') then '으로' else '로' end; -- 영·삼·육 받침 → '으로', 일·칠·팔(ㄹ)·그 외 → '로'
  end if;
  code := ascii(c);
  if code between 44032 and 55203 then
    if (code - 44032) % 28 = 0 or (code - 44032) % 28 = 8 then return '로'; end if;
    return '으로';
  end if;
  return '로';
end $$;

-- 06 §6 사유 템플릿
create or replace function reason_sentence(p_template text) returns text language sql immutable as $$
  select case p_template
    when 'steps_spike' then '걸음 기록이 평소보다 크게 높아 확인했어요'
    when 'source_unknown' then '확인되지 않은 출처의 운동 기록이 있었어요'
    when 'dup_photo' then '같은 사진이 두 번 이상 사용됐어요'
    when 'downward_edit' then '확정값이 AI 추정보다 절반 넘게 낮았어요'
    when 'skip_abuse' then '''건너뜀''이 한도를 넘었어요'
    else null end
$$;

-- 통지 문장 = 사유 문장 + 판정 문장 + 점수 영향 문장 (그 외 문구 금지)
create or replace function verdict_message(p_template text, p_verdict verdict_type, p_impact jsonb) returns text
  language plpgsql immutable as $$
declare v_sentence text; v_effect text; v_reason text := reason_sentence(p_template); v_sub text;
begin
  case p_verdict
    when 'approve' then v_sentence := '확인이 끝났어요'; v_effect := '점수 변동 없음';
    when 'warn' then v_sentence := format('이번은 경고 %s/3이에요', p_impact ->> 'warning_count'); v_effect := '점수 변동 없음';
    when 'exclude' then v_sentence := '경고가 3회 누적되어 이번 챌린지 순위에서 빠졌어요'; v_effect := '점수와 기록은 계속 볼 수 있어요';
    when 'void' then
      v_sub := p_impact ->> 'substitution';
      v_sentence := v_sub || josa_ro(v_sub) || ' 다시 계산했어요';
      v_effect := format('%s %s→%s점 · 누적 %s', format_md((p_impact ->> 'local_date')::date),
        format_k1((p_impact ->> 's_before')::numeric), format_k1((p_impact ->> 's_after')::numeric),
        format_signed1((p_impact ->> 'cumulative_after')::numeric - (p_impact ->> 'cumulative_before')::numeric));
  end case;
  return concat_ws('. ', v_reason, v_sentence, v_effect);
end $$;

-- 판정 적용. p_dry_run=true 면 같은 변경을 서브트랜잭션에서 적용·계산 후 되돌려 점수 영향만 돌려준다.
-- void 대체 처리(04 §7 "무효 시 처리"):
--   dup_photo → 끼니 void(대체값 M_p, 간식은 삭제와 같음) / downward_edit → ai_kcal 복원
--   steps_spike → 세션 밖 걸음 = baseline_median_steps / source_unknown → 해당 출처 세션·걸음 제외 / skip_abuse → 초과분은 이미 M_p
create or replace function apply_verdict(p_review_id uuid, p_verdict verdict_type, p_dry_run boolean default true,
  p_actor uuid default null, p_reason_template text default null, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  rv reviews;
  p participants;
  ds daily_scores;
  v_impact jsonb;
  v_before numeric; v_after numeric; v_cum_before numeric; v_cum_after numeric;
  v_sub text;
  v_warn int;
  v_msg text;
  v_tpl text;
  v_after_score daily_scores;
begin
  select * into rv from reviews where id = p_review_id for update;
  if not found then raise exception 'review not found' using errcode = 'PT404'; end if;
  if rv.status = 'decided' then raise exception 'already decided' using errcode = 'PT409'; end if;
  select * into p from participants where id = rv.participant_id;
  -- 호출자 권한: Edge Function 이 운영자 확인 후 service_role 로 호출. 직접 RPC 는 운영자만.
  if auth.uid() is not null and not is_challenge_operator(rv.challenge_id) then
    raise exception 'operator only' using errcode = 'PT403';
  end if;
  v_tpl := coalesce(p_reason_template, rv.reason_template, case when rv.type::text in
    ('steps_spike', 'source_unknown', 'dup_photo', 'downward_edit', 'skip_abuse') then rv.type::text end);

  select * into ds from daily_scores where participant_id = p.id and local_date = rv.local_date;
  v_before := ds.s_d;
  v_cum_before := participant_cumulative(p.id);
  v_warn := p.warning_count;

  if p_verdict = 'void' then
    case rv.type
      when 'dup_photo' then v_sub := '대체값 ' || to_char(ceil(ds.m_p), 'FM999,999');
      when 'downward_edit' then v_sub := 'AI 추정값 복원';
      when 'steps_spike' then v_sub := '평소 걸음 기준';
      when 'source_unknown' then v_sub := '해당 출처 제외';
      when 'skip_abuse' then v_sub := '대체값 ' || to_char(ceil(ds.m_p), 'FM999,999');
      else v_sub := '기록 기준';
    end case;
    begin
      case rv.type
        when 'dup_photo' then
          update meals set status = 'void' where id = (rv.target ->> 'meal_id')::uuid;
        when 'downward_edit' then
          update meals set confirmed_kcal = ai_kcal, status = case when status = 'corrected' then status else 'corrected' end
          where id = (rv.target ->> 'meal_id')::uuid;
        when 'steps_spike' then
          update daily_activity set steps_out_override = coalesce(p.baseline_median_steps, 0)
          where participant_id = p.id and local_date = rv.local_date;
        when 'source_unknown' then
          update activity_sessions set is_counted = false, excluded_reason = 'verdict'
          where participant_id = p.id and local_date = rv.local_date and origin = rv.target ->> 'origin';
          update daily_activity set steps_excluded = coalesce((select sum((src ->> 'steps')::int) from jsonb_array_elements(sources) src
            where src ->> 'origin' = rv.target ->> 'origin'), 0)
          where participant_id = p.id and local_date = rv.local_date;
        else null;
      end case;
      v_after_score := recompute_day(p.id, rv.local_date, 'verdict', rv.id, p_actor);
      v_after := v_after_score.s_d;
      v_cum_after := participant_cumulative(p.id);
      if p_dry_run then raise exception using errcode = 'P0D01', message = 'dry-run rollback'; end if;
    exception when sqlstate 'P0D01' then
      null; -- 서브트랜잭션 롤백, 계산값(v_after·v_cum_after)은 변수에 남는다
    end;
  else
    v_after := v_before; v_cum_after := v_cum_before;
    if p_verdict = 'warn' then v_warn := least(3, v_warn + 1); end if;
    if p_verdict = 'exclude' then v_warn := 3; end if;
  end if;

  v_impact := jsonb_build_object('local_date', rv.local_date, 's_before', v_before, 's_after', v_after,
    'cumulative_before', v_cum_before, 'cumulative_after', v_cum_after, 'delta', coalesce(v_after, 0) - coalesce(v_before, 0),
    'm_p', ds.m_p, 'substitution', v_sub, 'warning_count', v_warn, 'excluded', v_warn >= 3, 'provisional', not coalesce(ds.is_final, false));
  v_msg := verdict_message(v_tpl, p_verdict, v_impact);
  v_impact := v_impact || jsonb_build_object('message', v_msg);
  if p_dry_run then
    return v_impact || jsonb_build_object('dry_run', true);
  end if;

  if p_verdict in ('warn', 'exclude') then
    update participants set warning_count = v_warn, rank_eligible = case when v_warn >= 3 then false else rank_eligible end,
      status = case when v_warn >= 3 then 'excluded'::participant_status else status end
    where id = p.id;
  end if;
  update reviews set status = 'decided', verdict = p_verdict, reason_template = v_tpl, score_impact = v_impact,
    decided_at = p_now, decided_by = p_actor, message = v_msg
  where id = rv.id;
  -- 검토 중 해제 후 재계산(void 는 위에서 이미 반영, under_review 갱신 포함)
  perform recompute_day(p.id, rv.local_date, 'verdict', rv.id, p_actor);
  perform enqueue_notification(p.user_id, rv.challenge_id, 'N-06', '판정 결과', v_msg,
    jsonb_build_object('review_id', rv.id, 'verdict', p_verdict), p_now);
  perform write_audit(rv.challenge_id, p_actor, 'operator', 'verdict',
    jsonb_build_object('review_id', rv.id, 'verdict', p_verdict, 'template', v_tpl), to_jsonb(ds), v_impact);
  return v_impact || jsonb_build_object('dry_run', false);
end $$;

-- ---------------------------------------------------------------- 생명주기 (03 §7)
create or replace function challenge_open_review_count(p_challenge_id uuid) returns int
  language sql stable as $$
  select count(*)::int from reviews where challenge_id = p_challenge_id and status in ('open', 'appealed')
$$;

create or replace function transition_challenge(p_challenge_id uuid, p_to challenge_status, p_actor uuid default null,
  p_now timestamptz default now()) returns jsonb
  language plpgsql as $$
declare
  ch challenges;
  v_open int;
  v_ok boolean;
begin
  select * into ch from challenges where id = p_challenge_id for update;
  if not found then raise exception 'challenge not found' using errcode = 'PT404'; end if;
  if auth.uid() is not null and not is_challenge_operator(p_challenge_id) then
    raise exception 'operator only' using errcode = 'PT403';
  end if;
  v_ok := (ch.status, p_to) in (
    ('draft', 'recruiting'), ('recruiting', 'draft'), ('recruiting', 'checking'), ('checking', 'running'),
    ('running', 'closing'), ('closing', 'published'), ('published', 'archived'),
    ('draft', 'cancelled'), ('recruiting', 'cancelled'));
  if not v_ok then
    raise exception 'transition % → % not allowed', ch.status, p_to using errcode = 'PT422';
  end if;
  if (ch.status, p_to) = ('recruiting'::challenge_status, 'draft'::challenge_status)
     and exists (select 1 from participants where challenge_id = ch.id) then
    raise exception '참가자가 있어 비공개로 되돌릴 수 없어요' using errcode = 'PT422';
  end if;
  if p_to = 'published' then
    v_open := challenge_open_review_count(ch.id);
    if v_open > 0 then
      raise exception '미결 %건', v_open using errcode = 'PT422', detail = jsonb_build_object('open_reviews', v_open)::text;
    end if;
  end if;
  if p_to = 'recruiting' and ch.invite_code is null then
    update challenges set invite_code = new_invite_code() where id = ch.id;
  end if;
  if p_to = 'checking' then
    update challenge_rules set locked_at = p_now where challenge_id = ch.id and locked_at is null; -- 상수·프로필 잠금
  end if;
  update challenges set status = p_to, published_at = case when p_to = 'published' then p_now else published_at end
  where id = ch.id;
  if p_to = 'published' then
    perform build_leaderboard(ch.id, 'cumulative', ch.end_date, true, p_now);
  end if;
  perform write_audit(ch.id, p_actor, case when p_actor is null then 'system' else 'operator' end, 'transition',
    jsonb_build_object('from', ch.status, 'to', p_to));
  return jsonb_build_object('challenge_id', ch.id, 'from', ch.status, 'to', p_to);
end $$;

-- 00:00 KST 생명주기 배치 [제안]: Recruiting→Checking(시작일), Checking→Running(3일), Published→Archived(7일)
create or replace function run_lifecycle(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare ch challenges; v_today date := kst_date(p_now); n int := 0; r challenge_rules;
begin
  for ch in select * from challenges where status in ('recruiting', 'checking', 'published')
  loop
    r := engine_rules(ch.id);
    if ch.status = 'recruiting' and v_today >= ch.start_date then
      perform transition_challenge(ch.id, 'checking', null, p_now); n := n + 1;
    elsif ch.status = 'checking' and v_today >= ch.start_date + r.check_days then
      perform transition_challenge(ch.id, 'running', null, p_now); n := n + 1;
    elsif ch.status = 'published' and p_now >= ch.published_at + interval '7 days' then
      perform transition_challenge(ch.id, 'archived', null, p_now); n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function new_invite_code() returns char(6) language plpgsql volatile as $$
declare v text; alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  loop
    v := '';
    for i in 1..6 loop v := v || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1); end loop;
    exit when not exists (select 1 from challenges where invite_code = v);
  end loop;
  return v;
end $$;

-- ---------------------------------------------------------------- 건강 신호 (04 §8, 09:10 [제안])
-- 확정 섭취(대체값 제외) < 넛지 임계 3일 연속 → low_intake_3d + N-07 / A_raw > C 3일 연속 → high_activity_3d + N-07
create or replace function run_health_check(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare
  d date := kst_date(p_now) - 1;
  p record; n int := 0; r challenge_rules;
begin
  for p in select pt.*, ch.id as ch_id from participants pt join challenges ch on ch.id = pt.challenge_id
    where ch.status in ('checking', 'running', 'closing') and pt.status in ('active', 'record_mode', 'excluded')
  loop
    r := engine_rules(p.ch_id);
    if (select count(*) from daily_scores ds where ds.participant_id = p.id and ds.local_date between d - 2 and d and ds.is_final
        and coalesce(ds.i_confirmed, 0) + coalesce(ds.i_snack, 0) < case when p.sex = 'M' then r.nudge_min_m else r.nudge_min_f end) = 3 then
      insert into health_alerts (participant_id, challenge_id, type, local_date, detail)
      values (p.id, p.ch_id, 'low_intake_3d', d, jsonb_build_object('from', d - 2, 'to', d))
      on conflict do nothing;
      if found then
        perform enqueue_notification(p.user_id, p.ch_id, 'N-07', '건강 안내', '최근 섭취 기록이 적어요. 점수와 무관하게 충분히 드세요', '{}', p_now);
        n := n + 1;
      end if;
    end if;
    if (select count(*) from daily_activity a where a.participant_id = p.id and a.local_date between d - 2 and d and a.a_raw > r.c) = 3 then
      insert into health_alerts (participant_id, challenge_id, type, local_date, detail)
      values (p.id, p.ch_id, 'high_activity_3d', d, jsonb_build_object('from', d - 2, 'to', d))
      on conflict do nothing;
      if found then
        perform enqueue_notification(p.user_id, p.ch_id, 'N-07', '건강 안내', '최근 활동 기록이 많아요. 점수와 무관하게 충분히 쉬어 주세요', '{}', p_now);
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $$;

-- 09:30 N-01 어제 확정 결과 / 21:00 N-02 조건부 리마인드
create or replace function enqueue_daily_results(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare d date := kst_date(p_now) - 1; x record; n int := 0; v_rank int;
begin
  for x in select ds.*, pt.user_id, pt.rank_eligible, pt.challenge_id as ch from daily_scores ds
    join participants pt on pt.id = ds.participant_id join challenges c on c.id = pt.challenge_id
    where ds.local_date = d and ds.is_final and c.status in ('checking', 'running', 'closing')
  loop
    select (r ->> 'rank')::int into v_rank from leaderboard_snapshots s, jsonb_array_elements(s.rows) r
      where s.challenge_id = x.ch and s.scope = 'cumulative' and s.is_final and s.local_date = d
        and r ->> 'participant_id' = x.participant_id::text
      order by s.as_of desc limit 1;
    perform enqueue_notification(x.user_id, x.ch, 'N-01', '어제 결과',
      case when x.rank_eligible and v_rank is not null then format('어제 %s점, 누적 %s위', format_k1(x.s_d), v_rank)
        else format('어제 %s점', format_k1(x.s_d)) end, jsonb_build_object('local_date', d), p_now);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function enqueue_reminders(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare d date := kst_date(p_now); x record; n int := 0;
begin
  for x in select pt.* from participants pt join challenges c on c.id = pt.challenge_id
    where c.status in ('checking', 'running') and d between c.start_date and c.end_date and pt.status in ('active', 'record_mode', 'excluded')
  loop
    if exists (select 1 from meals m where m.participant_id = x.id and m.local_date = d and m.status in ('captured', 'draft', 'failed')) then
      perform enqueue_notification(x.user_id, x.challenge_id, 'N-02', '확정 대기', '사진이 확정을 기다려요', jsonb_build_object('local_date', d), p_now);
      n := n + 1;
    elsif not exists (select 1 from daily_activity a where a.participant_id = x.id and a.local_date = d) then
      perform enqueue_notification(x.user_id, x.challenge_id, 'N-02', '동기화', '앱을 열면 걸음이 동기화돼요', jsonb_build_object('local_date', d), p_now);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
