-- 시작 후 참가·동시 3개·참가 마감·남은 기간·나가기(D47·D50), 월간 참가는 코드 없이
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); t date := kst_date();
begin
  -- 월간(진행 중, 30일, 오늘 2일째), 운영자 챌린지 3개(진행 중), 마감 임박 1개, 참가 마감 1개, 마감(closing) 1개
  insert into challenges (id, name, kind, status, start_date, end_date, capacity, operator_id) values
    ('11111111-0000-4000-a000-000000000001', '시험 월간', 'monthly', 'running', t - 1, t + 28, null, op);
  insert into challenges (id, name, status, start_date, end_date, capacity, invite_code, operator_id, join_open) values
    ('11111111-0000-4000-a000-000000000002', '운영 1', 'running', t - 5, t + 20, 30, 'OPONE1', op, true),
    ('11111111-0000-4000-a000-000000000003', '운영 2', 'running', t - 5, t + 20, 30, 'OPTWO2', op, true),
    ('11111111-0000-4000-a000-000000000004', '운영 3', 'checking', t - 1, t + 20, 30, 'OPTRE3', op, true),
    ('11111111-0000-4000-a000-000000000005', '마감 임박', 'running', t - 20, t + 5, 30, 'SHORT5', op, true),
    ('11111111-0000-4000-a000-000000000006', '참가 마감', 'running', t - 5, t + 20, 30, 'CLOSE6', op, false),
    ('11111111-0000-4000-a000-000000000007', '정리 중', 'closing', t - 25, t, 30, 'DONE07', op, true);
  insert into challenge_rules (challenge_id, locked_at)
  select id, now() from challenges where id::text like '11111111-0000-4000-a000-00000000000%';
  insert into auth.users (id) values ('22222222-0000-4000-a000-000000000001');
end $$;
select tests.login('22222222-0000-4000-a000-000000000001');
set local role authenticated;
do $$
declare r jsonb; j text := '"nickname":"동시참가","sex":"F","birth_year":1990,"height_cm":160,"weight_kg":55,"consents":{"terms":true,"sensitive_health":true}';
  mon uuid := '11111111-0000-4000-a000-000000000001';
begin
  perform tests.ok(exists (select 1 from jsonb_array_elements(open_challenges()) e
    where e ->> 'challenge_id' = mon::text and (e ->> 'joinable')::boolean and e ->> 'me' is null), '열린 월간 목록: 참가 가능·미참가');
  r := join_challenge(format('{"challenge_id":"%s",%s}', mon, j)::jsonb);
  perform tests.eq(r ->> 'kind', 'monthly', '월간: 코드 없이 참가');
  perform tests.eq((r ->> 'check_start')::date, kst_date(), '진행 중 참가 → 점검은 오늘부터');
  perform tests.throws(format('select join_challenge(''{"challenge_id":"%s",%s}'')', '11111111-0000-4000-a000-000000000002', j), 'PT404', '운영자 챌린지는 id 로 참가 불가(코드 필요)');
  r := join_challenge(format('{"code":"opone1",%s}', j)::jsonb);
  perform tests.ok(r ? 'participant_id', '운영자 챌린지: 진행 중에도 코드로 참가');
  r := join_challenge(format('{"code":"OPTWO2",%s}', j)::jsonb);
  perform tests.throws(format('select join_challenge(''{"code":"OPTRE3",%s}'')', j), 'PT409', '동시 참가 3개 초과 거부', '%3개%');
  perform tests.throws(format('select join_challenge(''{"code":"CLOSE6",%s}'')', j), 'PT403', '참가 마감 거부');
  perform tests.throws(format('select join_challenge(''{"code":"SHORT5",%s}'')', j), 'PT422', '남은 기간으로 최소 참여일을 못 채우면 거부');
  perform tests.throws(format('select join_challenge(''{"code":"DONE07",%s}'')', j), 'PT404', '마감(closing) 챌린지는 참가 불가');
  perform tests.ok((join_challenge(format('{"challenge_id":"%s",%s}', mon, j)::jsonb) ? 'participant_id'), '이미 참가 중이면 다시 참가(3개 제한에 걸리지 않음)');

  perform tests.eq(jsonb_array_length(my_challenges()), 3, '내 챌린지 3개');
  perform tests.eq(challenge_session(mon) #>> '{challenge,kind}', 'monthly', '챌린지별 세션');
  perform tests.ok(challenge_session(mon) ? 'stats', '세션에 순위 통계');
  perform tests.eq((my_challenge_summary() #>> '{challenge,capacity}')::int >= 0, true, '이전 앱 요약: 정원은 숫자');

  r := leave_challenge(mon);
  perform tests.eq(r ->> 'status', 'left', '나가기');
  perform tests.throws(format('select join_challenge(''{"challenge_id":"%s",%s}'')', mon, j), 'PT403', '나간 챌린지는 다시 참가 불가');
  perform tests.throws(format('select leave_challenge(%L)', mon), 'PT404', '참가 중이 아니면 나가기 불가');
  perform tests.eq(jsonb_array_length(my_challenges()), 2, '나간 챌린지는 목록에서 빠짐');
  r := join_challenge(format('{"code":"OPTRE3",%s}', j)::jsonb);
  perform tests.ok(r ? 'participant_id', '하나 나가면 다시 3개까지');
end $$;
reset role;
do $$ begin
  perform tests.eq((select status::text || ':' || rank_eligible || ':' || block_rejoin from participants
    where challenge_id = '11111111-0000-4000-a000-000000000001' and user_id = '22222222-0000-4000-a000-000000000001'),
    'left:false:true', '나가기 = left·순위 제외·재참가 차단');
  perform tests.ok(exists (select 1 from audit_logs where action = 'participant_leave'), '나가기 감사 로그');
  perform tests.eq(get_invite('opone1') ->> 'kind', 'operator', '초대 조회에 종류');
end $$;
rollback;
