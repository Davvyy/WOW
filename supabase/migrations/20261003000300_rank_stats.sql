-- 순위(docs/02 D49): 순위 점수 = 일평균 × (1 + 참여율).
--   참여일 = 확정·반영 대상인 날 수(기록 없는 날의 0점 포함), 일평균 = Σ S_d ÷ 참여일
--   참여율 = 참여일 ÷ 반영 가능 일수, 반영 가능 일수 = (챌린지에서 확정된 마지막 날까지의 경과 일수) − check_days
--   최소 참여일 = greatest(1, least(최종 최소 참여일, 반영 가능 일수 / 2)), 최종 = least(7, (일수 − check_days) / 2)
--   최소 참여일 미만은 '순위 대기'(score null)
create or replace function participant_rank_stats(p_participant uuid, p_date date) returns jsonb
  language plpgsql stable as $$
declare
  p participants; ch challenges; r challenge_rules;
  v_days int; v_total numeric; v_meals int; v_horizon date;
  v_avail int; v_min_final int; v_min int; v_avg numeric; v_rate numeric;
begin
  select * into p from participants where id = p_participant;
  if not found then return null; end if;
  select * into ch from challenges where id = p.challenge_id;
  r := engine_rules(ch.id);
  select count(*)::int, coalesce(sum(s_d), 0), coalesce(sum(main_meal_count), 0)::int into v_days, v_total, v_meals
    from daily_scores where participant_id = p_participant and is_counted and is_final and local_date <= p_date;
  select max(local_date) into v_horizon from daily_scores where challenge_id = ch.id and is_final and local_date <= p_date;
  v_avail := case when v_horizon is null then 0 else greatest(0, (v_horizon - ch.start_date + 1) - r.check_days) end;
  v_min_final := least(7, ((ch.end_date - ch.start_date + 1) - r.check_days) / 2);
  v_min := greatest(1, least(v_min_final, v_avail / 2));
  v_avg := case when v_days > 0 then v_total / v_days end;
  v_rate := case when v_avail > 0 then least(1, v_days::numeric / v_avail) end;
  return jsonb_build_object('days', v_days, 'total', v_total, 'meals', v_meals, 'avail', v_avail, 'min_days', v_min,
    'avg', round(v_avg, 1), 'rate', round(v_rate, 3), 'pending', v_days < v_min,
    'score', case when v_days >= v_min then round(v_avg * (1 + coalesce(v_rate, 0)), 1) end);
end $$;
revoke execute on function participant_rank_stats(uuid, date) from public, anon, authenticated;
grant execute on function participant_rank_stats(uuid, date) to service_role;

-- 리더보드 스냅샷(05 §7). 누적은 순위 점수(D49), 오늘은 S_d 그대로.
-- rows: rank_eligible·leaderboard_visible 참가자만. 검토 중인 행은 타인에게 '집계 중'(이름·점수·id 비공개).
-- 동점 공동 순위 1-2-2-4, 표시 순서 = 점수 → 확정 끼니 수 → 닉네임. 순위 대기는 rank 0·pending true 로 맨 뒤.
create or replace function build_leaderboard(p_challenge uuid, p_scope leaderboard_scope, p_date date, p_is_final boolean,
  p_as_of timestamptz default now())
  returns uuid language plpgsql as $$
declare v_rows jsonb; v_id uuid;
begin
  with base as (
    select p.id, p.nickname, p.grade_badge, p.grade_badge_public,
      case when p_scope = 'cumulative' then participant_rank_stats(p.id, p_date) end as st,
      ds.s_d as today_score, coalesce(ds.main_meal_count, 0) as today_meals,
      exists (select 1 from reviews rv where rv.participant_id = p.id and rv.status in ('open', 'appealed')
        and rv.type not in ('session_anomaly', 'manual_input_burst', 'late_upload', 'photo_mismatch', 'objection')) as under_review,
      -- 반영률 4칸: 아침·점심·저녁 확정 + 활동 동기화(표시 전용, 05 §5.3)
      (select count(*) from (select distinct m.slot from meals m where m.participant_id = p.id and m.local_date = p_date
         and m.slot <> 'snack' and m.counted and m.status in ('confirmed', 'auto', 'corrected') and m.confirmed_kcal >= 150) z)
        + case when exists (select 1 from daily_activity a where a.participant_id = p.id and a.local_date = p_date and a.synced_at is not null) then 1 else 0 end as fill,
      (select count(*) from cheers c where c.to_participant_id = p.id and c.local_date = p_date) as cheer_count
    from participants p
    left join daily_scores ds on ds.participant_id = p.id and ds.local_date = p_date
    where p.challenge_id = p_challenge and p.rank_eligible and p.leaderboard_visible
      and (p.status = 'active' or (p.status = 'left' and p.user_id is null)) -- 탈퇴 참가자: 익명 점수 유지(05 §8)
  ), scored as (
    select *,
      case when p_scope = 'today' then coalesce(today_score, 0) else (st ->> 'score')::numeric end as score,
      case when p_scope = 'today' then today_meals else coalesce((st ->> 'meals')::int, 0) end as meals,
      p_scope = 'cumulative' and coalesce((st ->> 'pending')::boolean, true) as pending
    from base
  ), ranked as (
    select *, case when pending then 0 else rank() over (partition by pending order by score desc) end as rnk,
      row_number() over (order by pending, score desc nulls last, meals desc, nickname) as ord
    from scored
  ), tied as (
    select *, not pending and count(*) over (partition by pending, rnk) > 1 as tie from ranked
  )
  select coalesce(jsonb_agg(case when under_review then
      jsonb_build_object('rank', rnk, 'aggregating', true, 'fill', 0, 'pending', pending)
    else jsonb_build_object('rank', rnk, 'participant_id', id, 'nickname', nickname, 'score', score,
      'fill', fill, 'cheer_count', cheer_count, 'badge', case when grade_badge_public then grade_badge end, 'tie', tie)
      || case when p_scope = 'cumulative' then jsonb_build_object('pending', pending, 'avg', (st ->> 'avg')::numeric,
           'rate', (st ->> 'rate')::numeric, 'days', (st ->> 'days')::int, 'min_days', (st ->> 'min_days')::int) else '{}'::jsonb end
    end order by ord), '[]')
  into v_rows from tied;

  insert into leaderboard_snapshots (challenge_id, scope, local_date, as_of, is_final, rows)
  values (p_challenge, p_scope, p_date, p_as_of, p_is_final, v_rows) returning id into v_id;
  return v_id;
end $$;
