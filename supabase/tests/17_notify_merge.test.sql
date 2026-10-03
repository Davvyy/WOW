-- 알림 묶음(D53): N-02·N-01 은 사용자당 1건, payload 에 challenge_ids
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); ji uuid := tests.pid('지수'); uid uuid := tests.uid('지수');
  x uuid; xp uuid; m uuid; n jsonb;
begin
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('공유 시험', 'running', '2026-10-01', '2026-10-31', 30, op) returning id into x;
  insert into challenge_rules (challenge_id, locked_at) values (x, now());
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select x, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-10-01 09:00+09'
  from participants where id = ji returning id into xp;
  -- 오늘(10.13) 확정 대기 끼니 1개(대표 + 복사본)
  insert into meals (participant_id, challenge_id, local_date, slot, status, engine) values (ji, (select challenge_id from participants where id = ji), '2026-10-13', 'dinner', 'draft', 'gemini')
    returning id into m;
  insert into meals (participant_id, challenge_id, local_date, slot, status, engine, record_group_id) values (xp, x, '2026-10-13', 'dinner', 'draft', 'gemini', m);
  delete from notifications where user_id = uid;

  perform enqueue_reminders('2026-10-13 21:00+09');
  perform tests.eq((select count(*)::int from notifications where user_id = uid and type = 'N-02'), 1, 'N-02 사용자당 1건');
  select payload into n from notifications where user_id = uid and type = 'N-02';
  perform tests.eq(jsonb_array_length(n -> 'challenge_ids'), 2, 'N-02 payload 에 두 챌린지');
  perform tests.ok((n ->> 'pending')::int >= 1, '대표 끼니 기준 확정 대기 수');

  insert into daily_scores (participant_id, challenge_id, local_date, s_d, is_counted, is_final) values (xp, x, '2026-10-12', 30.5, true, true);
  perform enqueue_daily_results('2026-10-13 09:30+09');
  perform tests.eq((select count(*)::int from notifications where user_id = uid and type = 'N-01'), 1, 'N-01 사용자당 1건');
  perform tests.ok((select body from notifications where user_id = uid and type = 'N-01') like '%가을 걷기 챌린지%' and
    (select body from notifications where user_id = uid and type = 'N-01') like '%공유 시험 30.5점%', 'N-01 본문에 챌린지별 점수');
  perform tests.ok((select (select count(*) from notifications o where o.user_id = p.user_id and o.type = 'N-01') = 1
    from participants p where p.id = tests.pid('밤산책')), '참가 1개인 사람도 1건');
end $$;
rollback;
