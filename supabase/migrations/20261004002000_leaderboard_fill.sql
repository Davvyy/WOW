-- 순위표 반영률(fill)을 앱 홈과 같은 기준으로 맞춘다(D69).
-- 전에는 확정 기록 150 kcal 이상만 셌고(D59 의 snack_kcal 0 이 반영되지 않음) 건너뜀은 세지 않아,
-- 아침을 한도 안에서 건너뛴 날 홈은 75%, 순위표는 50% 로 달랐다.
-- 원래 정의(20261003000300_rank_stats.sql)에서 fill 계산만 바꿨다.
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
      -- 반영률 4칸(표시 전용, 05 §5.3): 아침·점심·저녁은 대체값이 들어가지 않은 칸 + 활동 동기화. 앱 홈과 같은 기준(D69).
      -- 칸을 채운 확정 기록(규칙 snack_kcal 이상) 또는 한도 안의 건너뜀(그날 점수의 대체 칸 목록에 없음).
      (select count(*) from (select s.slot from unnest(array['breakfast', 'lunch', 'dinner']::meal_slot[]) s(slot)
         where exists (select 1 from meals m where m.participant_id = p.id and m.local_date = p_date and m.slot = s.slot
                         and m.counted and m.status in ('confirmed', 'auto', 'corrected')
                         and coalesce(m.confirmed_kcal, 0) >= (engine_rules(p.challenge_id)).snack_kcal)
            or (exists (select 1 from meals m where m.participant_id = p.id and m.local_date = p_date and m.slot = s.slot
                          and m.status = 'skipped')
                and not coalesce(ds.breakdown -> 'intake' -> 'substitute_slots' ? s.slot::text, false))) z)
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
