-- 09:00 확정이 다음 날 잠정 행도 다시 계산한다(docs/02 D61).
-- 빈 칸 대체값 = max(M_p, 전날 같은 칸 등록 kcal). 확정 배치가 D 의 초안을 자동 확정하면 D 의 칸 kcal 이 바뀌므로,
-- D 를 확정한 뒤 D+1 행이 있고 확정 전이면 D+1 을 잠정으로 다시 계산한다(recompute_day 와 같은 하루 연쇄).
-- 원본(20261003000200_challenge_kinds.sql)에서 바꾼 것: 그 연쇄(v_next_final)만.

create or replace function run_finalize(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare
  ch challenges;
  r challenge_rules;
  d date := kst_date(p_now) - 1;
  p participants;
  res daily_scores;
  v_next_final boolean;
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
      -- 다음 날 대체값이 이 날 칸 kcal 에 기대므로 다음 날 잠정 행도 다시 계산(확정된 다음 날은 그대로)
      select is_final into v_next_final from daily_scores where participant_id = p.id and local_date = d + 1;
      if found and not v_next_final then
        perform compute_daily_score(p.id, d + 1, 'provisional');
      end if;
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
