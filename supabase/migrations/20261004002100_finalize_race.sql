-- 매시 잠정 계산(challory-provisional, 0 * * * *)과 09:00 확정(challory-finalize, 0 0 * * *)이 같은 순간에 돌 때
-- 잠정 쪽이 확정 전 행을 읽고 확정 뒤에 저장하면 is_final 을 false 로 덮어써 확정이 풀렸다(10.4·10.5 실제 발생, D70).
-- compute_daily_score 를 ① 그날 행을 잠그고 읽고 ② 잠정 계산이 확정 행을 덮지 않게 바꾼다. 확정 여부·확정 시각은 한 번 정해지면 유지.
-- 원래 정의(20261004001100_prev_day_substitute.sql)에서 이 두 군데만 바꿨다.
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
  v_prev jsonb;
  a jsonb; i jsonb; s jsonb;
  v_m numeric;
  v_under_review boolean;
  v_is_final boolean;
begin
  select * into p from participants where id = p_participant;
  if not found then raise exception 'participant % not found', p_participant using errcode = 'P0002'; end if;
  select * into ch from challenges where id = p.challenge_id;
  -- 참가 전 날짜는 계산하지 않는다(중간 참가, D48). 동기화가 최근 3일을 보내도 점수 행을 만들지 않는다.
  if p_date < p.check_start then return null; end if;
  r := engine_rules(p.challenge_id);
  -- 같은 날 행을 잠그고 읽는다: 매시 잠정 계산과 09:00 확정이 동시에 돌면 뒤에 온 쪽이 기다렸다가 최신 행(확정)을 본다(D70)
  select * into prev from daily_scores where participant_id = p_participant and local_date = p_date for update;

  if p_mode = 'provisional' and prev.is_final then
    return prev; -- 확정 뒤에는 정정 경로로만 바뀐다(04 §5.4)
  end if;

  v_m := m_p(p.bmr_locked, r);
  if p_mode = 'finalize' then
    -- 04 §4.3 미확정 AI 초안 자동 확정
    -- 간식 초안은 대체값 하한 없이 auto_confirm × AI(D55)
    update meals set status = 'auto',
      confirmed_kcal = case when slot = 'snack' then r.auto_confirm * coalesce(ai_kcal, 0)
                            else greatest(v_m, r.auto_confirm * coalesce(ai_kcal, 0)) end,
      delta_ratio = case when ai_kcal > 0 then
                      case when slot = 'snack' then r.auto_confirm
                           else greatest(v_m, r.auto_confirm * ai_kcal) / ai_kcal end end,
      confirmed_at = now()
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
  -- 전날 칸별 등록 kcal(D61): 확정 기록만, 간식 칸 제외. 점검 시작일 전 날은 없음(M_p).
  select coalesce(jsonb_object_agg(z.slot, z.kcal), '{}') into v_prev from (
    select m.slot::text as slot, sum(coalesce(m.confirmed_kcal, 0)) as kcal
    from meals m
    where m.participant_id = p_participant and m.local_date = p_date - 1 and m.counted
      and m.status in ('confirmed', 'auto', 'corrected') and m.slot <> 'snack'
      and p_date - 1 >= p.check_start
    group by m.slot) z;
  i := intake_kcal(p.bmr_locked, v_meals, v_skips, r, v_prev);
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
        'sessions', v_sessions, 'meals', v_meals, 'skips_used_this_week', v_skips, 'platform_active_kcal', da.platform_active_kcal,
        'prev_slots', v_prev)),
    now())
  on conflict (participant_id, local_date) do update set
    bmr = excluded.bmr, a_d = excluded.a_d, i_confirmed = excluded.i_confirmed, i_snack = excluded.i_snack,
    substitute_slots = excluded.substitute_slots, m_p = excluded.m_p, i_d = excluded.i_d, f_p = excluded.f_p,
    d_d = excluded.d_d, s_d = excluded.s_d, main_meal_count = excluded.main_meal_count, is_counted = excluded.is_counted,
    is_final = d.is_final or excluded.is_final, finalized_at = coalesce(d.finalized_at, excluded.finalized_at),
    under_review = excluded.under_review, breakdown = excluded.breakdown, computed_at = excluded.computed_at
  -- 잠정 계산은 확정된 행을 덮지 않는다(행이 없던 사이 다른 쪽이 먼저 확정해 넣은 경우까지, D70)
  where not (d.is_final and p_mode = 'provisional')
  returning * into res;
  if res.id is null then
    select * into res from daily_scores where participant_id = p_participant and local_date = p_date;
  end if;

  if prev.is_final and p_mode = 'revise' and (prev.s_d is distinct from res.s_d or prev.i_d is distinct from res.i_d or prev.a_d is distinct from res.a_d) then
    insert into score_revisions (daily_score_id, participant_id, prev_s_d, new_s_d, prev_breakdown, reason, review_id, actor_id)
    values (res.id, p_participant, prev.s_d, res.s_d, prev.breakdown, coalesce(p_reason, 'user_edit'), p_review_id, p_actor);
  end if;
  return res;
end $$;

-- 확정 작업을 잠정 작업과 5분 어긋나게(가드가 있어도 같은 순간 경합을 줄인다). pg_cron 이 없으면(로컬) 건너뛴다.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $q$select cron.alter_job(jobid, schedule := '5 0 * * *') from cron.job where jobname = 'challory-finalize'$q$;
  end if;
end $$;
