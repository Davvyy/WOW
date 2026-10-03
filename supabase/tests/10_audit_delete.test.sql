-- 감사 로그가 있는 챌린지 삭제(docs/02 D54): 로그는 남고 challenge_id 만 비워진다. 그 밖의 수정·삭제는 계속 막힌다.
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); ch uuid; v_log bigint;
begin
  insert into challenges (name, start_date, end_date, capacity, operator_id)
  values ('지울 챌린지', '2026-12-01', '2026-12-14', 30, op) returning id into ch;
  perform write_audit(ch, op, 'operator', 'challenge_create', '{}');
  select max(id) into v_log from audit_logs;
  delete from challenges where id = ch;
  perform tests.ok(not exists (select 1 from challenges where id = ch), '감사 로그가 있어도 챌린지 삭제');
  perform tests.eq((select challenge_id from audit_logs where id = v_log), null::uuid, '감사 로그는 남고 challenge_id 만 null');
  perform tests.eq((select action from audit_logs where id = v_log), 'challenge_create', '로그 내용 그대로');
  perform tests.throws(format('update audit_logs set action = ''x'' where id = %s', v_log), 'P0001', '내용 수정은 거부', '%append-only%');
  perform tests.throws(format('delete from audit_logs where id = %s', v_log), 'P0001', '삭제는 거부', '%append-only%');
end $$;
rollback;
