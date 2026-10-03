-- 챌린지 종류·참가 마감·개인 점검 기간·자동 이어하기 (docs/02 D46·D47·D48·D51)
create type challenge_kind as enum ('operator', 'monthly');
alter table challenges
  add column kind challenge_kind not null default 'operator',
  add column join_open boolean not null default true,
  alter column capacity drop not null,
  add constraint challenges_capacity_by_kind check (kind = 'monthly' or capacity is not null);
create unique index challenges_monthly_uidx on challenges (start_date) where kind = 'monthly';

alter table profiles add column auto_continue boolean not null default true;

-- 개인 점검 기간 시작일: 챌린지 시작일과 참가일(KST) 중 늦은 날
alter table participants add column check_start date;
update participants p set check_start = greatest(c.start_date, kst_date(p.joined_at)) from challenges c where c.id = p.challenge_id;
alter table participants alter column check_start set not null;
create or replace function participants_check_start() returns trigger language plpgsql as $$
begin
  if new.check_start is null then
    select greatest(c.start_date, kst_date(new.joined_at)) into new.check_start from challenges c where c.id = new.challenge_id;
  end if;
  return new;
end $$;
create trigger participants_check_start before insert on participants for each row execute function participants_check_start();
revoke execute on function participants_check_start() from public, anon, authenticated;

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
    and rv.status in ('open', 'appealed') and rv.type not in ('session_anomaly', 'manual_input_burst', 'late_upload', 'photo_mismatch', 'objection'))
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
    (p_date - p.check_start) >= r.check_days, -- 개인 점검 기간(D48)
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
      -- 참가 전 날짜는 계산하지 않는다(중간 참가, D48)
      for p in select id from participants where challenge_id = ch.id and status in ('active', 'record_mode', 'excluded')
        and check_start <= d
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
      continue when d < p.check_start; -- 참가 전 날짜(D48)
      if exists (select 1 from daily_scores where participant_id = p.id and local_date = d and is_final) then continue; end if;
      res := compute_daily_score(p.id, d, 'finalize');
      n := n + 1;
      -- 건너뜀 초과 → skip_abuse 플래그(초과분은 이미 M_p, 판정은 경고)
      if (res.breakdown #>> '{intake,skip_over}')::boolean then
        perform raise_flag(p.id, d, 'skip_abuse', jsonb_build_object('key', d::text), p_now);
      end if;
      -- 개인 점검 기간 마지막 날: 기준선 중앙값(steps_spike 콜드스타트)
      if d - p.check_start + 1 = r.check_days then
        update participants set baseline_median_steps = (
          select percentile_cont(0.5) within group (order by greatest(0, a.steps_total - coalesce(a.steps_manual, 0)))::int
          from daily_activity a where a.participant_id = p.id and a.local_date between p.check_start and d)
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
