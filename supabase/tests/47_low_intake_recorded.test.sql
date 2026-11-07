-- 섭취 부족 건강 신호(low_intake_3d): 끼니가 모두 정해진 날(대체값이 들어간 끼니 없음)만 센다.
-- 기록이 없는 날은 "확정 섭취 0"이 아니라 알 수 없는 날이다. 3일 내내 기록이 빠져 N-07 22건이 잘못 나간 문제(D83).
begin;
create function pg_temp.alert_for(p_sub1 jsonb, p_sub2 jsonb, p_sub3 jsonb, p_kcal numeric default 800) returns boolean language plpgsql as $$
declare me uuid := tests.pid('밤산책');
begin
  delete from health_alerts where participant_id = me;
  update daily_scores d set is_final = true, i_confirmed = p_kcal, i_snack = 0,
    breakdown = jsonb_set(jsonb_set(coalesce(d.breakdown, '{}'), '{intake}', coalesce(d.breakdown -> 'intake', '{}')), '{intake,substitute_slots}',
      case d.local_date when '2026-10-09' then p_sub1 when '2026-10-10' then p_sub2 else p_sub3 end)
  where d.participant_id = me and d.local_date between '2026-10-09' and '2026-10-11';
  perform run_health_check('2026-10-12 09:10+09');
  return exists (select 1 from health_alerts where participant_id = me and type = 'low_intake_3d');
end $$;

do $$
declare none jsonb := '[]'; din jsonb := '["dinner"]'; all3 jsonb := '["breakfast","lunch","dinner"]'; me uuid := tests.pid('밤산책');
begin
  perform tests.eq((select count(*)::int from daily_scores where participant_id = me and local_date between '2026-10-09' and '2026-10-11'), 3, '시드: 3일치 점수 행');
  perform tests.ok(pg_temp.alert_for(none, none, none), '3일 모두 끼니가 정해졌고 적게 먹음: 알림');
  perform tests.ok(not pg_temp.alert_for(all3, all3, all3, 0), '3일 내내 기록 없음: 알림 없음');
  perform tests.ok(not pg_temp.alert_for(none, din, none), '하루라도 대체값이 있으면 3일 연속이 아님: 알림 없음');
  perform tests.ok(not pg_temp.alert_for(none, none, none, 1500), '끼니가 정해졌고 충분히 먹음: 알림 없음');
end $$;
rollback;
