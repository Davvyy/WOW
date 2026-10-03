-- RLS·권한 테스트: 참가자는 본인 행만, 운영자는 자기 챌린지만, 건강 알림은 운영자 전용.
begin;
-- 참가 테스트용 모집 중 챌린지·외부 사용자
insert into auth.users (id) values ('00000000-0000-4000-a000-000000000001'), ('00000000-0000-4000-a000-000000000002'),
  ('00000000-0000-4000-a000-000000000003'), ('00000000-0000-4000-a000-000000000004');
insert into challenges (id, name, status, start_date, end_date, capacity, invite_code, operator_id)
values ('00000000-0000-4000-a000-0000000000c1', '겨울 챌린지', 'recruiting', '2026-12-01', '2026-12-28', 30, 'WINTER',
  (select operator_id from challenges where invite_code = 'K7Q2MD'));
insert into challenge_rules (challenge_id) values ('00000000-0000-4000-a000-0000000000c1');

-- ---------------- 참가자(지수)
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare ji uuid := tests.pid('지수'); r jsonb; rv uuid;
begin
  perform tests.eq((select count(*)::int from participants), 1, '참가자: participants 본인 행만');
  perform tests.eq((select count(*)::int from daily_scores), 8, '참가자: daily_scores 본인 8일만');
  perform tests.eq((select count(*)::int from meals where participant_id <> ji), 0, '참가자: 타인 끼니 0');
  perform tests.eq((select count(*)::int from photos where participant_id <> ji), 0, '참가자: 타인 사진 0');
  perform tests.eq((select count(*)::int from daily_activity where participant_id <> ji), 0, '참가자: 타인 활동 0');
  perform tests.eq((select count(*)::int from health_alerts), 0, '참가자: 건강 알림 접근 불가');
  perform tests.eq((select count(*)::int from review_reporters), 0, '참가자: 신고자 비노출');
  perform tests.eq((select count(*)::int from participant_notes), 0, '참가자: 운영자 메모 접근 불가');
  perform tests.eq((select count(*)::int from audit_logs), 0, '참가자: 감사 로그 접근 불가');
  perform tests.eq((select count(*)::int from profiles), 1, '참가자: profiles 본인만');
  perform tests.eq((select count(*)::int from reviews), 1, '참가자: 본인 검토만(R-0415)');
  perform tests.ok((select count(*) from leaderboard_snapshots) > 0, '참가자: 리더보드 스냅샷 읽기');
  perform tests.ok((select count(*) from challenge_rules) = 1, '참가자: 규칙 상수 읽기(P11)');
  perform tests.eq((select count(*)::int from challenges), 1, '참가자: 소속 챌린지만');
  perform tests.throws('select * from sync_batches', '42501', '참가자: sync_batches 직접 조회 불가');

  -- 쓰기 제한
  perform tests.throws(format('update participants set status = ''excluded'' where id = %L', ji), 'PT403', '참가자: 상태 변경 불가');
  perform tests.throws(format('update participants set weight_locked = 60 where id = %L', ji), '42501', '참가자: 잠금 체중 변경 불가');
  perform tests.throws(format('update profiles set weight_kg = 60 where user_id = %L', tests.uid('지수')), 'PT422', '참가자: 시작 후 프로필 잠금');
  update participants set leaderboard_visible = false where id = ji;
  perform tests.ok(not (select leaderboard_visible from participants where id = ji), '참가자: 리더보드 숨김 설정');
  perform tests.throws(format('select apply_verdict_rpc(%L, ''void'', true)', (select id from reviews limit 1)), 'PT403', '참가자: 판정 불가');
  perform tests.throws(format('select ingest_activity_batch(%L, ''{}''::jsonb)', ji), '42501', '참가자: 배치 함수 직접 호출 불가');
  perform tests.throws(format('select confirm_meal(%L, %L, ''[]''::jsonb, 1)', tests.uid('지수'), (select id from meals limit 1)), '42501', '참가자: 확정 함수 직접 호출 불가');
  perform tests.throws(format('select run_finalize()'), '42501', '참가자: 배치 실행 불가');
  perform tests.throws(format('insert into daily_scores (participant_id, challenge_id, local_date) values (%L, (select challenge_id from participants where id = %L), ''2026-10-14'')', ji, ji), '42501', '참가자: 점수 직접 쓰기 불가');

  -- 응원 1일 1회(보내는 사람 기준)
  perform tests.throws(format('insert into cheers (challenge_id, from_participant_id, to_participant_id) values ((select challenge_id from participants where id = %L), %L, %L)',
    ji, tests.pid('밤산책'), ji), '42501', '응원: 남의 이름으로 보내기 불가');

  -- 소명 1회
  rv := (select id from reviews where participant_id = ji);
  insert into appeals (review_id, participant_id, text) values (rv, ji, '10.10 저녁과 같은 접시를 다시 찍었어요.');
  perform tests.eq((select status::text from reviews where id = rv), 'appealed', '소명 → appealed');
  perform tests.throws(format('insert into appeals (review_id, participant_id, text) values (%L, %L, ''다시'')', rv, ji), '42501', '소명 2회째 거부(open 아님)');

  -- 시뮬레이터 RPC(P11)
  r := score_simulate_from_inputs(jsonb_build_object('participant_id', ji, 'steps_total', 9000,
    'meals', '[{"slot":"breakfast","status":"confirmed","kcal":420},{"slot":"lunch","status":"confirmed","kcal":780},{"slot":"dinner","status":"confirmed","kcal":600}]'::jsonb));
  perform tests.eq((r ->> 's_d')::numeric, 28.8, '참가자: 내 숫자 시뮬레이터 28.8');
  perform tests.throws(format('select score_simulate_from_inputs(%L::jsonb)', jsonb_build_object('participant_id', tests.pid('밤산책'))::text), 'P0002', '참가자: 남의 participant_id 로 시뮬레이션 불가');
end $$;
reset role;

-- 응원: 같은 날 두 번째 응원은 거부
select tests.login(tests.uid('밤산책'));
set local role authenticated;
do $$
declare me uuid := tests.pid('밤산책');
begin
  perform tests.eq((select count(*)::int from daily_scores), 8, '밤산책: 본인 8일');
  insert into cheers (challenge_id, from_participant_id, to_participant_id) values ((select challenge_id from participants where id = me), me, tests.pid('지수'));
  perform tests.throws(format('insert into cheers (challenge_id, from_participant_id, to_participant_id) values ((select challenge_id from participants where id = %L), %L, %L)',
    me, me, tests.pid('강남콩')), '23505', '응원: 하루 1회(보내는 사람 기준)');
end $$;
reset role;

-- ---------------- 운영자(민호)
select tests.login((select operator_id from challenges where invite_code = 'K7Q2MD'));
set local role authenticated;
do $$
declare r jsonb; ch uuid := (select id from challenges where invite_code = 'K7Q2MD');
begin
  perform tests.eq((select count(*)::int from participants where challenge_id = ch), 12, '운영자: 참가자 12명');
  perform tests.eq((select count(*)::int from health_alerts), 2, '운영자: 건강 알림 비공개 섹션 2건');
  perform tests.eq((select count(*)::int from participant_notes), 1, '운영자: 메모');
  perform tests.eq((select count(*)::int from review_reporters), 1, '운영자: 신고 내용');
  perform tests.eq((select record_mode_reason::text from profiles where user_id = tests.uid('새벽커피')), 'bmi', '운영자: 기록 모드 사유(드로어 운영자 전용)');
  perform tests.ok((select count(*) from daily_scores) >= 96, '운영자: 전체 장부');
  perform tests.ok((select count(*) from v_challenge_summary) = 2, '운영자: OP0 요약 뷰');
  perform tests.eq((select open_reviews from v_challenge_summary where id = ch), 3, '운영자: 미결 3건');
  perform tests.ok((select count(*) from v_participant_sync where challenge_id = ch) = 12, '운영자: OP2 동기화 뷰');
  r := apply_verdict_rpc((select id from reviews where target ->> 'code' = 'R-0415'), 'void', true);
  perform tests.eq((r ->> 's_after')::numeric, 12.7, '운영자: 판정 dry-run');
  perform tests.throws(format('select transition_challenge_rpc(%L, ''published'')', ch), 'PT422', '운영자: 진행 중 → 발표 불가');
  update challenge_rules set t = 400 where challenge_id = ch;
  perform tests.eq((select t from challenge_rules where challenge_id = ch), 500::numeric, '운영자: 잠긴 상수 변경 안 됨');
  perform tests.throws(format('update challenges set capacity = 99 where id = %L', ch), 'PT422', '운영자: 시작 후 정원 변경 불가');
  update participants set status = 'kicked', block_rejoin = true where id = tests.pid('한강러너');
  perform tests.eq((select rank_eligible from participants where id = tests.pid('한강러너')), false, '운영자: 강퇴 → 순위 제외');
  perform tests.ok(exists (select 1 from audit_logs where action = 'participant_status'), '운영자: 상태 변경 감사 로그');
  perform tests.throws(format('update participants set nickname = ''x'' where id = %L', tests.pid('지수')), 'PT403', '운영자: 참가자 닉네임 변경 불가');
  perform tests.throws('insert into audit_logs (actor_role, action) values (''operator'', ''x'')', '42501', '운영자: 감사 로그 직접 쓰기 불가');
end $$;
-- 새 챌린지(OP0): 초안 + 기본 규칙 행, 초대코드는 모집 시작 때
do $$
declare r jsonb; d date := kst_date(now()) + 1; bad text := 'select create_challenge(%L)';
begin
  r := create_challenge(jsonb_build_object('name', '  봄 걷기 챌린지  ', 'start_date', d, 'end_date', d + 13, 'capacity', 40));
  perform tests.eq((select status::text from challenges where id = (r ->> 'id')::uuid), 'draft', '운영자: 새 챌린지는 초안');
  perform tests.eq((select name from challenges where id = (r ->> 'id')::uuid), '봄 걷기 챌린지', '이름 앞뒤 공백 제거');
  perform tests.ok(exists (select 1 from challenge_rules where challenge_id = (r ->> 'id')::uuid), '기본 규칙 행 함께 생성');
  perform tests.ok((select invite_code is null from challenges where id = (r ->> 'id')::uuid), '초대코드는 모집 시작 때 발급');
  perform tests.throws(format(bad, jsonb_build_object('name', 'x', 'start_date', d, 'end_date', d + 5, 'capacity', 40)), 'PT422', '기간 7일 미만 불가');
  perform tests.throws(format(bad, jsonb_build_object('name', 'x', 'start_date', d, 'end_date', d + 30, 'capacity', 40)), 'PT422', '기간 30일 초과 불가');
  perform tests.throws(format(bad, jsonb_build_object('name', 'x', 'start_date', d, 'end_date', d + 13, 'capacity', 29)), 'PT422', '정원 30명 미만 불가');
  perform tests.throws(format(bad, jsonb_build_object('name', ' ', 'start_date', d, 'end_date', d + 13, 'capacity', 40)), 'PT422', '이름 없으면 불가');
  perform tests.throws(format(bad, jsonb_build_object('name', 'x', 'start_date', d - 2, 'end_date', d + 11, 'capacity', 40)), 'PT422', '지난 날짜 시작 불가');
end $$;
reset role;

-- ---------------- 다른 운영자·외부인
select tests.login('00000000-0000-4000-a000-000000000001');
set local role authenticated;
do $$
begin
  perform tests.eq((select count(*)::int from challenges), 0, '외부인: 챌린지 0');
  perform tests.eq((select count(*)::int from leaderboard_snapshots), 0, '외부인: 리더보드 0');
  perform tests.eq((select count(*)::int from daily_scores), 0, '외부인: 장부 0');
  perform tests.throws('insert into challenges (name, start_date, end_date, capacity, operator_id) values (''x'', ''2026-12-01'', ''2026-12-02'', 10, ''00000000-0000-4000-a000-000000000001'')', '42501', '외부인: 운영자 아니면 챌린지 생성 불가');
  perform tests.throws('select create_challenge(''{"name":"x","start_date":"2099-01-01","end_date":"2099-01-10","capacity":40}'')', 'PT403', '외부인: 챌린지 생성 불가');
end $$;

-- 참가(P1~P3): 자격 게이트·기록 모드
do $$
declare r jsonb;
begin
  r := join_challenge('{"code":"winter","nickname":"겨울이","sex":"F","birth_year":1995,"height_cm":165,"weight_kg":48,"consents":{"terms":true,"sensitive_health":true}}');
  perform tests.ok((r ->> 'record_mode')::boolean, 'BMI 17.6 → 기록 모드');
  perform tests.eq((select rank_eligible from participants where id = (r ->> 'participant_id')::uuid), false, '기록 모드 → 순위 제외');
  perform tests.eq((select count(*)::int from consents where type = 'overseas_ai'), 0, '국외 AI 미동의 → 동의 행 없음');
  perform tests.throws('select join_challenge(''{"code":"NOPE00","nickname":"a","sex":"M","birth_year":1990,"height_cm":170,"weight_kg":70,"consents":{"terms":true,"sensitive_health":true}}'')', 'PT404', '없는 코드는 참가 불가');
end $$;
select tests.login('00000000-0000-4000-a000-000000000002');
do $$
declare r jsonb;
begin
  r := join_challenge('{"code":"WINTER","nickname":"고딩","sex":"M","birth_year":2009,"height_cm":172,"weight_kg":60,"consents":{"terms":true,"sensitive_health":true,"overseas_ai":true}}');
  perform tests.ok((r ->> 'record_mode')::boolean, '만 19세 미만(보수 판정) → 기록 모드');
  perform tests.eq((r ->> 'bmr')::int, 1600, '참가 시 BMR 잠금(raw 1,595 → round10 1,600)');
  -- 온보딩을 다시 거치거나 재시도해도 같은 결과(동의가 쌓이지 않음)
  r := join_challenge('{"code":"WINTER","nickname":"고딩","sex":"M","birth_year":2009,"height_cm":172,"weight_kg":60,"consents":{"terms":true,"sensitive_health":true,"overseas_ai":true}}');
  perform tests.eq((select count(*)::int from consents where user_id = auth.uid()), 3, '다시 참가해도 동의는 종류별 1건');
end $$;
select tests.login('00000000-0000-4000-a000-000000000003');
do $$ begin
  perform tests.throws('select join_challenge(''{"code":"WINTER","nickname":"중딩","sex":"M","birth_year":2013,"height_cm":160,"weight_kg":50,"consents":{"terms":true,"sensitive_health":true}}'')', 'PT422', '만 14세 미만 차단');
  perform tests.throws('select join_challenge(''{"code":"WINTER","nickname":"동의X","sex":"M","birth_year":1990,"height_cm":170,"weight_kg":70,"consents":{"terms":true}}'')', 'PT422', '필수 동의 없으면 참가 불가');
end $$;
reset role;

-- ---------------- 익명
set local role anon;
do $$ begin
  perform tests.eq(get_invite('k7q2md') ->> 'name', '가을 걷기 챌린지', '익명: 초대코드 조회');
  perform tests.throws('select * from challenges', '42501', '익명: 테이블 접근 불가');
end $$;
reset role;
rollback;

-- 운영자 콘솔 RPC
begin;
select tests.login((select operator_id from challenges where invite_code = 'K7Q2MD'));
set local role authenticated;
do $$
declare ch uuid := (select id from challenges where invite_code = 'K7Q2MD'); r jsonb;
begin
  r := announce_challenge(ch, '최종 결과는 11.3 09:00에 확정돼요', '마지막 날(11.2) 기록은 11.3 09:00에 확정돼요.');
  perform tests.eq((r ->> 'recipients')::int, 12, '공지 N-03 12명');
  r := export_rows(ch, 'scores');
  perform tests.ok(jsonb_array_length(r) >= 96, 'CSV scores 행');
  perform tests.ok(not (r -> 0 ? 'operator_note') and not (r -> 0 ? 'record_mode_reason'), 'CSV 금지 열 없음');
  perform tests.ok(jsonb_array_length(export_rows(ch, 'ranking')) > 0, 'CSV ranking');
  perform tests.throws(format('select purge_challenge_photos(%L)', ch), 'PT422', '진행 중에는 사진 파기 불가');
  perform tests.throws(format('select transition_challenge(%L, ''closing'', null, now())', ch), '42501', '전환은 래퍼로만');
  perform tests.eq(transition_challenge_rpc(ch, 'closing') ->> 'to', 'closing', '운영자 전환 래퍼');
  perform tests.ok(exists (select 1 from audit_logs where action = 'transition' and actor_id = auth.uid()), '전환 감사 로그 actor = 본인');
  perform log_operator_action(ch, 'rules_md_publish', '{"length": 10}');
end $$;
reset role;
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$ declare ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
begin
  perform tests.throws(format('select announce_challenge(%L, ''t'', ''b'')', ch), 'PT403', '참가자: 공지 불가');
  perform tests.throws(format('select export_rows(%L, ''scores'')', ch), 'PT403', '참가자: CSV 불가');
end $$;
reset role;
rollback;
