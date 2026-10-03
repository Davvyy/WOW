-- 순위(D49): 일평균 × (1 + 참여율), 참여율 분모 = 확정된 마지막 날까지의 경과 일수 − 3, 최소 참여일은 경과에 맞춰 늘어남
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); ch uuid;
  a uuid; b uuid; c uuid; st jsonb; snap jsonb;
begin
  -- 31일 챌린지(2026-12-01~12-31): 반영 가능 28일, 최종 최소 참여일 min(7, 14) = 7
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('순위 시험', 'running', '2026-12-01', '2026-12-31', 30, op) returning id into ch;
  insert into challenge_rules (challenge_id, locked_at) values (ch, now());
  a := tests.new_participant(ch, 'A참가', '2026-11-30 10:00+09');
  b := tests.new_participant(ch, 'B참가', '2026-12-15 10:00+09');
  c := tests.new_participant(ch, 'C참가', '2026-12-26 10:00+09');
  insert into daily_scores (participant_id, challenge_id, local_date, s_d, main_meal_count, is_counted, is_final)
  select a, ch, d, case when d >= '2026-12-04' then 40 else 0 end, 3, d >= '2026-12-04', true from generate_series('2026-12-01'::date, '2026-12-31', '1 day') d
  union all select b, ch, d, case when d >= '2026-12-18' then 60 else 0 end, 3, d >= '2026-12-18', true from generate_series('2026-12-15'::date, '2026-12-31', '1 day') d
  union all select c, ch, d, case when d >= '2026-12-29' then 100 else 0 end, 3, d >= '2026-12-29', true from generate_series('2026-12-26'::date, '2026-12-31', '1 day') d;

  st := participant_rank_stats(a, '2026-12-31');
  perform tests.eq((st ->> 'days')::int, 28, 'A 참여 28일');
  perform tests.eq((st ->> 'avail')::int, 28, '반영 가능 28일');
  perform tests.eq((st ->> 'score')::numeric, 80.0, 'A 평균 40 × (1 + 28/28) = 80');
  st := participant_rank_stats(b, '2026-12-31');
  perform tests.eq((st ->> 'score')::numeric, 90.0, 'B 평균 60 × (1 + 14/28) = 90');
  perform tests.eq((st ->> 'rate')::numeric, 0.5, 'B 참여율 0.5');
  st := participant_rank_stats(c, '2026-12-31');
  perform tests.ok((st ->> 'pending')::boolean and st ->> 'score' is null, 'C 3일 < 7일 → 순위 대기');
  perform tests.eq((st ->> 'min_days')::int, 7, '마감 때 최소 참여일 7');

  -- 진행 중(12.8): 반영 가능 5일 → 최소 참여일 min(7, 5/2) = 2
  st := participant_rank_stats(a, '2026-12-08');
  perform tests.eq((st ->> 'min_days')::int, 2, '12.8 최소 참여일 2');
  perform tests.eq((st ->> 'score')::numeric, 80.0, '12.8 A 평균 40 × (1 + 5/5) = 80');
  perform tests.ok((participant_rank_stats(b, '2026-12-08') ->> 'pending')::boolean, '12.8 B 참여 0일 → 순위 대기');
  -- 확정 전 날짜는 분모에 넣지 않는다
  update daily_scores set is_final = false where challenge_id = ch and local_date = '2026-12-08';
  perform tests.eq((participant_rank_stats(a, '2026-12-08') ->> 'avail')::int, 4, '확정된 마지막 날(12.7)까지로 분모 계산');

  perform build_leaderboard(ch, 'cumulative', '2026-12-31', true, '2027-01-01 09:00+09');
  select rows into snap from leaderboard_snapshots where challenge_id = ch and scope = 'cumulative' order by as_of desc limit 1;
  perform tests.eq(snap -> 0 ->> 'nickname', 'B참가', '1위 B(90)');
  perform tests.eq((snap -> 0 ->> 'rank')::int, 1, 'B rank 1');
  perform tests.eq((snap -> 0 ->> 'avg')::numeric, 60.0, '행에 일평균');
  perform tests.eq(snap -> 1 ->> 'nickname', 'A참가', '2위 A(80)');
  perform tests.eq(snap -> 2 ->> 'nickname', 'C참가', '순위 대기는 맨 뒤');
  perform tests.ok((snap -> 2 ->> 'pending')::boolean and (snap -> 2 ->> 'rank')::int = 0 and snap -> 2 ->> 'score' is null, '순위 대기 행: rank 0·점수 없음');
  perform tests.eq((snap -> 2 ->> 'days')::int, 3, '순위 대기 행에 참여일');
end $$;
rollback;
