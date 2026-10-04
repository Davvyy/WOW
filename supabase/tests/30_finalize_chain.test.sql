-- 09:00 확정(run_finalize)이 D 의 초안을 자동 확정하면 D+1 빈 칸 대체값 max(M_p, 전날 같은 칸)도 바뀐다(D61).
-- 그래서 확정 뒤 D+1 행이 있고 확정 전이면 D+1 도 잠정으로 다시 계산한다(recompute_day 와 같은 하루 연쇄).
-- 지수 10.14~10.16 은 시드 끼니가 없다.
begin;
do $$
declare
  ji uuid := tests.pid('지수');
  ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
  v_m numeric; lunch uuid; d15 daily_scores; n15 int;
begin
  v_m := m_p((select bmr_locked from participants where id = ji), engine_rules(ch));
  perform tests.ok(v_m < 1170, format('지수 M_p %s < 1.3 × 900', v_m));

  -- D = 10.14: 확정하지 않은 AI 초안 점심 900
  insert into meals (participant_id, challenge_id, local_date, slot, status, ai_kcal)
    values (ji, ch, '2026-10-14', 'lunch', 'draft', 900) returning id into lunch;
  perform compute_daily_score(ji, '2026-10-14', 'provisional');

  -- D+1 = 10.15: 점심이 비어 있는 잠정 행. 초안은 등록 kcal 이 아니라 아직 M_p
  d15 := compute_daily_score(ji, '2026-10-15', 'provisional');
  perform tests.ok(not d15.is_final, '10.15 는 잠정');
  perform tests.eq((d15.breakdown #>> '{intake,substitute_values,lunch}')::numeric, v_m, '확정 전: 10.15 점심 대체값 M_p');
  n15 := (select count(*)::int from daily_scores where local_date = '2026-10-15');

  -- 10.15 09:00 확정 배치 → 10.14 초안 자동 확정 max(M_p, 1.3 × 900) = 1170
  perform run_finalize('2026-10-15 09:00+09');
  perform tests.eq((select status::text || ':' || confirmed_kcal from meals where id = lunch), 'auto:1170.0', '10.14 점심 자동 확정 1,170');
  perform tests.ok((select is_final from daily_scores where participant_id = ji and local_date = '2026-10-14'), '10.14 확정');

  select * into d15 from daily_scores where participant_id = ji and local_date = '2026-10-15';
  perform tests.ok(not d15.is_final, '10.15 는 여전히 잠정');
  perform tests.eq((d15.breakdown #>> '{intake,substitute_values,lunch}')::numeric, 1170::numeric,
    '확정 뒤: 10.15 점심 대체값 = 10.14 점심 1,170');
  perform tests.eq((d15.breakdown #>> '{inputs,prev_slots,lunch}')::numeric, 1170::numeric, '입력에 전날 점심 1,170');
  perform tests.eq(d15.i_d, r1(2 * v_m + 1170), 'I_d = M_p × 2 + 1,170');
  perform tests.eq((select count(*)::int from daily_scores where local_date = '2026-10-15'), n15, '다음 날 행이 없던 참가자는 만들지 않음');
end $$;
rollback;

-- 확정된 다음 날은 바뀌지 않는다
begin;
do $$
declare
  ji uuid := tests.pid('지수');
  ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
  v_m numeric;
begin
  v_m := m_p((select bmr_locked from participants where id = ji), engine_rules(ch));
  insert into meals (participant_id, challenge_id, local_date, slot, status, ai_kcal) values (ji, ch, '2026-10-14', 'lunch', 'draft', 900);
  perform compute_daily_score(ji, '2026-10-15', 'provisional');
  update daily_scores set is_final = true where participant_id = ji and local_date = '2026-10-15';
  perform run_finalize('2026-10-15 09:00+09');
  perform tests.eq((select (breakdown #>> '{intake,substitute_values,lunch}')::numeric from daily_scores
    where participant_id = ji and local_date = '2026-10-15'), v_m, '확정된 10.15 는 그대로 M_p');
end $$;
rollback;
