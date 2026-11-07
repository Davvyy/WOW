-- 건너뜀은 하루 2회까지(D84). 주 3회 한도는 그대로. 새 챌린지 기본값과 진행 중인 월간 챌린지에 적용하고, 끝난 챌린지는 그대로.
begin;
do $$
declare ch uuid; p record; v_old uuid; v_new uuid; op uuid;
begin
  perform tests.eq((default_rules()).skip_per_day, 2, '규칙 행이 없을 때 하루 2회');
  perform tests.eq((default_rules()).skip_per_week, 3, '주 3회는 그대로');
  select operator_id into op from challenges where invite_code = 'K7Q2MD';
  insert into challenges (name, status, start_date, end_date, capacity, operator_id) values ('스킵 새 챌린지', 'draft', '2027-01-04', '2027-01-31', 30, op) returning id into v_new;
  insert into challenge_rules (challenge_id) values (v_new);
  perform tests.eq((select skip_per_day from challenge_rules where challenge_id = v_new), 2, '새 규칙 행 기본값 2');
end $$;
rollback;

-- 진행 중 월간 챌린지는 2회로 올리고, 집계 마감 뒤 챌린지와 운영자 챌린지는 건드리지 않는 조건을 확인한다
begin;
do $$
declare ji uuid := tests.pid('지수'); uid uuid := tests.uid('지수'); r jsonb;
begin
  delete from meals where participant_id = ji and local_date = '2026-10-13';
  r := skip_meal(uid, ji, '2026-10-13', 'breakfast');
  perform tests.ok(not (r ->> 'over_limit')::boolean, '기본 규칙: 첫 건너뜀 허용');
  r := skip_meal(uid, ji, '2026-10-13', 'lunch');
  perform tests.ok(not (r ->> 'over_limit')::boolean, '기본 규칙: 두 번째 건너뜀도 허용');
  r := skip_meal(uid, ji, '2026-10-13', 'dinner');
  perform tests.ok((r ->> 'over_limit')::boolean, '세 번째 건너뜀은 한도 초과');
end $$;
rollback;
