-- 섭취 부족 건강 신호(low_intake_3d)는 끼니가 모두 정해진 날만 센다(docs/02 D83).
-- 지금까지 기록이 없는 날을 "확정 섭취 0"으로 세어, 3일 연속 기록이 없으면 N-07 "섭취 기록이 적어요"가 나갔다(22건 중 20건).
-- 대체값이 들어간 끼니가 있는 날은 실제로 얼마나 먹었는지 알 수 없어 세지 않는다. 건너뜀은 대체값이 아니라 그대로 센다.
-- 나머지 본문은 20261001000300 그대로.

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
        and coalesce(jsonb_array_length(ds.breakdown -> 'intake' -> 'substitute_slots'), 0) = 0
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
