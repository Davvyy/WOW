-- 배치·판정·동기화 테스트 (시드 = 프로토타입 예시, 오늘 2026-10-13 D+8)
begin;
do $$
declare
  ji uuid := tests.pid('지수');
  r jsonb;
  ch uuid := (select id from challenges where invite_code = 'K7Q2MD');
  rv uuid := (select id from reviews where target ->> 'code' = 'R-0415');
begin
  -- 시드 점수 = 프로토타입 LEDGER
  perform tests.eq((select s_d from daily_scores where participant_id = ji and local_date = '2026-10-13'), 28.8::numeric(5,1), '지수 오늘 잠정 28.8');
  perform tests.eq((select s_d from daily_scores where participant_id = ji and local_date = '2026-10-12'), 41.2::numeric(5,1), '지수 10.12 정정 전 41.2');
  perform tests.eq((select s_d from daily_scores where participant_id = tests.pid('밤산책') and local_date = '2026-10-13'), 72.1::numeric(5,1), '밤산책 오늘 72.1');
  perform tests.eq(participant_cumulative(ji), 341.1, '지수 누적(확정분, 점검 3일 제외) 341.1');
  perform tests.eq((select count(*)::int from daily_scores where participant_id = ji and is_final), 7, 'D1~D7 확정');
  perform tests.eq((select count(*)::int from daily_scores where participant_id = ji and is_counted), 5, '누적 반영 D4~D8');
  perform tests.eq((select bmr_locked from participants where id = ji), 1650, 'BMR 1,650');
  perform tests.eq((select baseline_median_steps from participants where id = ji), 9480, '기준선 중앙값(D1~D3)');
  perform tests.ok((select under_review from daily_scores where participant_id = ji and local_date = '2026-10-12'), '10.12 검토 중');

  -- 판정 dry-run: 10.12 저녁 무효 → 41.2→12.7, 누적 341.1→312.6, 아무것도 바뀌지 않음
  r := apply_verdict(rv, 'void', true, null, null, '2026-10-13 21:30+09');
  perform tests.eq((r ->> 's_before')::numeric, 41.2, 'dry-run 전 41.2');
  perform tests.eq((r ->> 's_after')::numeric, 12.7, 'dry-run 후 12.7');
  perform tests.eq((r ->> 'cumulative_after')::numeric, 312.6, 'dry-run 누적 312.6');
  perform tests.eq(r ->> 'message', '같은 사진이 두 번 이상 사용됐어요. 대체값 743으로 다시 계산했어요. 10.12 41.2→12.7점 · 누적 −28.5', '통지 문장 = 사유+판정+점수 영향');
  perform tests.eq((select status::text from meals where id = (select (target ->> 'meal_id')::uuid from reviews where id = rv)), 'confirmed', 'dry-run 은 끼니를 바꾸지 않음');
  perform tests.eq(participant_cumulative(ji), 341.1, 'dry-run 뒤 누적 그대로');
  perform tests.eq((select count(*)::int from score_revisions where participant_id = ji), 0, 'dry-run 은 revision 없음');
  perform tests.eq((select status::text from reviews where id = rv), 'open', 'dry-run 은 검토 상태 유지');

  -- 경고·승인 미리보기 문장
  perform tests.eq(apply_verdict(rv, 'warn', true) ->> 'message', '같은 사진이 두 번 이상 사용됐어요. 이번은 경고 1/3이에요. 점수 변동 없음', '경고 문장');
  perform tests.eq(apply_verdict(rv, 'approve', true) ->> 'message', '같은 사진이 두 번 이상 사용됐어요. 확인이 끝났어요. 점수 변동 없음', '승인 문장');

  -- 확정
  r := apply_verdict(rv, 'void', false, (select operator_id from challenges where id = ch), null, '2026-10-13 21:31+09');
  perform tests.eq((select s_d from daily_scores where participant_id = ji and local_date = '2026-10-12'), 12.7::numeric(5,1), '확정 후 10.12 12.7');
  perform tests.eq(participant_cumulative(ji), 312.6, '확정 후 누적 312.6');
  perform tests.eq((select prev_s_d || '→' || new_s_d || ':' || reason from score_revisions where participant_id = ji), '41.2→12.7:verdict', 'score_revisions 정정 이력');
  perform tests.eq((select status::text || ':' || verdict::text from reviews where id = rv), 'decided:void', '검토 판정 저장');
  perform tests.ok(not (select under_review from daily_scores where participant_id = ji and local_date = '2026-10-12'), '검토 중 해제');
  perform tests.eq((select body from notifications where user_id = tests.uid('지수') and type = 'N-06'), r ->> 'message', 'N-06 당사자 푸시 = 판정 문장');
  perform tests.eq((select category::text from notifications where user_id = tests.uid('지수') and type = 'N-06'), 'transactional', 'N-06 transactional');
  perform tests.ok(exists (select 1 from audit_logs where action = 'verdict' and target ->> 'review_id' = rv::text), '감사 로그');
  perform tests.throws(format('select apply_verdict(%L, ''approve'', false)', rv), 'PT409', '판정 중복 거부');

  -- 발표 차단: 미결 2건(R-0412·R-0417)
  update challenges set status = 'closing' where id = ch;
  perform tests.eq(challenge_open_review_count(ch), 2, '미결 2건');
  perform tests.throws(format('select transition_challenge(%L, ''published'')', ch), 'PT422', 'Published 전환 차단', '미결 2건');
  perform tests.throws(format('select transition_challenge(%L, ''running'')', ch), 'PT422', '허용되지 않는 전환');
end $$;
rollback;

-- 경고 3회 → 순위 제외, 리더보드에서 빠짐
begin;
do $$
declare oi uuid := tests.pid('오이냉국'); rv uuid := (select id from reviews where target ->> 'code' = 'R-0417'); r jsonb; snap jsonb;
begin
  perform tests.eq((select warning_count from participants where id = oi), 2, '오이냉국 경고 2');
  r := apply_verdict(rv, 'warn', false);
  perform tests.eq((r ->> 'warning_count')::int, 3, '경고 3/3');
  perform tests.ok(not (select rank_eligible from participants where id = oi), '경고 3회 → 순위 제외');
  perform build_leaderboard((select challenge_id from participants where id = oi), 'cumulative', '2026-10-13', false);
  select rows into snap from leaderboard_snapshots order by created_at desc, as_of desc limit 1;
  perform tests.ok(not exists (select 1 from jsonb_array_elements(snap) e where e ->> 'nickname' = '오이냉국'), '리더보드 rows 에서 제외');
  perform tests.ok(not exists (select 1 from jsonb_array_elements(snap) e where e ->> 'nickname' = '새벽커피'), '기록 모드 참가자 rows 제외');
  perform tests.ok(exists (select 1 from jsonb_array_elements(snap) e where (e ->> 'aggregating')::boolean and e ->> 'nickname' is null and e ->> 'participant_id' is null), '검토 중 행은 집계 중(이름·점수 비공개)');
end $$;
rollback;

-- 동기화 배치: 멱등성·플래그·지연 도착·세션 병합
begin;
do $$
declare
  ji uuid := tests.pid('지수'); r jsonb; b jsonb; bid uuid := gen_random_uuid();
begin
  b := jsonb_build_object('client_batch_id', bid, 'tz', 'Asia/Seoul', 'days', jsonb_build_array(
    jsonb_build_object('local_date', '2026-10-13', 'steps_total', 26000, 'floors', 12,
      'sources', jsonb_build_array(jsonb_build_object('origin', 'com.sec.android.app.shealth', 'method', 'AUTOMATICALLY_RECORDED')),
      'sessions', jsonb_build_array(
        jsonb_build_object('platform_uid', 'hc:watch-run', 'type', 'running', 'start', '2026-10-13T07:00:00+09:00', 'end', '2026-10-13T07:30:00+09:00',
          'distance_m', 4500, 'steps_in_range', 4500, 'origin', 'com.sec.android.app.shealth', 'method', 'AUTOMATICALLY_RECORDED'),
        jsonb_build_object('platform_uid', 'hc:phone-run', 'type', 'running', 'start', '2026-10-13T07:05:00+09:00', 'end', '2026-10-13T07:25:00+09:00',
          'distance_m', 3000, 'steps_in_range', 3000, 'origin', 'com.sec.android.app.shealth', 'method', 'AUTOMATICALLY_RECORDED'),
        jsonb_build_object('platform_uid', 'hc:manual', 'type', 'running', 'start', '2026-10-13T18:00:00+09:00', 'end', '2026-10-13T19:00:00+09:00',
          'distance_m', 10000, 'steps_in_range', 0, 'origin', 'com.sec.android.app.shealth', 'method', 'MANUAL_ENTRY'))),
    jsonb_build_object('local_date', '2026-10-12', 'steps_total', 30000, 'sources', '[]'::jsonb),
    jsonb_build_object('local_date', '2026-10-20', 'steps_total', 1)));
  r := ingest_activity_batch(ji, b, '2026-10-13 21:40+09');
  perform tests.eq((select is_counted from activity_sessions where platform_uid = 'hc:phone-run'), false, 'T06 겹치는 짧은 세션 병합(is_counted=false)');
  perform tests.ok((select merged_into_id from activity_sessions where platform_uid = 'hc:phone-run') = (select id from activity_sessions where platform_uid = 'hc:watch-run'), 'merged_into_id = 긴 세션');
  perform tests.eq((select is_counted from activity_sessions where platform_uid = 'hc:manual'), false, 'T05 수동 입력 세션 제외');
  -- A = 걸음 (26000−4500)×0.032667 + 세션 7.5×70×0.5 + 층수 12×2.0 → 702.3+262.5+23.7
  perform tests.eq((select a_d from daily_scores where participant_id = ji and local_date = '2026-10-13'), 988.5, '배치 후 A_d(병합·수동 제외·층수)');
  perform tests.ok(exists (select 1 from reviews where participant_id = ji and type = 'steps_spike' and local_date = '2026-10-13'), 'T21 걸음 26,000 → steps_spike');
  perform tests.ok((select under_review from daily_scores where participant_id = ji and local_date = '2026-10-13'), '검토 중(잠정 유지)');
  perform tests.ok((select late_delta is not null from daily_activity where participant_id = ji and local_date = '2026-10-12'), 'T18 확정 후 도착 → late_delta');
  perform tests.eq((select steps_total from daily_activity where participant_id = ji and local_date = '2026-10-12'), 10898, 'T18 확정 값 불변');
  perform tests.ok(r -> 'days' @> '[{"local_date": "2026-10-20", "rejected": "out_of_window"}]', '윈도 밖 날짜 거부');
  perform tests.eq((select scheduled_at from notifications where user_id = tests.uid('지수') and type = 'N-05' order by created_at desc limit 1),
    '2026-10-13 21:40+09'::timestamptz, 'N-05 08~22시 생성분 즉시');
  -- 같은 배치 재전송 → 저장된 결과, 다른 본문 → 409
  perform tests.ok((ingest_activity_batch(ji, b, '2026-10-13 21:41+09') ->> 'replayed')::boolean, '같은 client_batch_id 재전송은 저장 결과');
  perform tests.throws(format('select ingest_activity_batch(%L, %L::jsonb)', ji, (b || '{"tz":"UTC"}')::text), 'PT409', '같은 키 다른 본문 409');
end $$;
rollback;

-- 자정 분할·22시 이후 N-05 지연·출처 미확인
begin;
do $$
declare hani uuid := tests.pid('달려라하니');
begin
  perform ingest_activity_batch(hani, jsonb_build_object('client_batch_id', gen_random_uuid(), 'days', jsonb_build_array(
    jsonb_build_object('local_date', '2026-10-13', 'steps_total', 8000,
      'sources', jsonb_build_array(jsonb_build_object('origin', 'com.unknown.stepfaker')),
      'sessions', jsonb_build_array(jsonb_build_object('platform_uid', 'hk:night', 'type', 'running',
        'start', '2026-10-12T23:40:00+09:00', 'end', '2026-10-13T00:20:00+09:00', 'distance_m', 6000, 'steps_in_range', 6000,
        'origin', 'com.apple.health', 'method', 'AUTOMATICALLY_RECORDED'))))), '2026-10-13 23:10+09');
  perform tests.eq((select count(*)::int from activity_sessions where platform_uid = 'hk:night'), 1, '확정된 10.12 분할분은 넣지 않고 10.13 분할분만');
  perform tests.eq((select steps_in_range from activity_sessions where platform_uid = 'hk:night' and local_date = '2026-10-13'), 3000, '자정 분할 걸음 비례 배분');
  perform tests.ok(exists (select 1 from reviews where participant_id = hani and type = 'source_unknown'), '미확인 출처 → source_unknown');
  perform tests.eq((select scheduled_at from notifications where user_id = tests.uid('달려라하니') and type = 'N-05' order by created_at desc limit 1),
    '2026-10-14 08:00+09'::timestamptz, '22시 이후 생성 N-05 → 다음 08:00');
end $$;
rollback;

-- 식사 확정·하향 수정·48h 정정 창·동일 재전송
begin;
do $$
declare
  ji uuid := tests.pid('지수'); uid uuid := tests.uid('지수'); m meals; r jsonb; v int;
begin
  -- 오늘 점심(초안 850)을 김 해제(780)로 다시 확정 → 변동 없음 확인용으로 우선 초안 상태로 되돌림
  update meals set status = 'draft', confirmed_kcal = null, items_hash = null where participant_id = ji and local_date = '2026-10-13' and slot = 'lunch' returning * into m;
  perform compute_daily_score(ji, '2026-10-13');
  perform tests.eq((select i_d from daily_scores where participant_id = ji and local_date = '2026-10-13'), 2125.0, 'T23 초안 850 → 잠정 1,105 산입');
  r := confirm_meal(uid, m.id, jsonb_build_array(
    jsonb_build_object('chosen_name', '흰쌀밥', 'food_code', 'D000001', 'portion_multiplier', 1, 'count', 1),
    jsonb_build_object('chosen_name', '김치찌개', 'food_code', 'D000010', 'portion_multiplier', 1, 'count', 1),
    jsonb_build_object('chosen_name', '계란말이', 'food_code', 'D000020', 'portion_multiplier', 1, 'count', 2),
    jsonb_build_object('chosen_name', '멸치볶음', 'food_code', 'D000030', 'portion_multiplier', 1, 'count', 1),
    jsonb_build_object('chosen_name', '배추김치', 'food_code', 'D000040', 'portion_multiplier', 1, 'count', 1),
    jsonb_build_object('chosen_name', '김', 'food_code', 'D000050', 'portion_multiplier', 1, 'count', 1, 'eaten', false)), m.version, '2026-10-13 12:30+09');
  perform tests.eq((r ->> 'confirmed_kcal')::numeric, 780::numeric, '김 해제 → 780 확정');
  perform tests.eq((r ->> 's_d')::numeric, 28.8, '확정 후 28.8 (I −325)');
  v := (r ->> 'version')::int;
  perform tests.throws(format('select confirm_meal(%L, %L, ''[]''::jsonb, %s)', uid, m.id, v - 1), 'PT412', 'If-Match 버전 불일치 412');
  perform tests.throws(format('select confirm_meal(%L, %L, ''[]''::jsonb, %s)', tests.uid('밤산책'), m.id, v), 'PT403', '남의 끼니 확정 거부');
  -- 국물 안 먹음 ×0.6, 곱빼기 ×1.5 (T16)
  perform tests.eq(meal_item_kcal(310, 1.5, 1, false), 465.0, 'T16 밥 곱빼기 ×1.5');
  perform tests.eq(meal_item_kcal(260, 1, 1, true), 156.0, 'T16 국물 안 먹음 ×0.6');
  -- 하향 수정 −50% 초과 → 플래그, 값 유지 (T13)
  update meals set ai_kcal = 800 where id = m.id;
  r := confirm_meal(uid, m.id, jsonb_build_array(jsonb_build_object('chosen_name', '직접 입력', 'serving_kcal', 390, 'input_type', 'manual')), v, '2026-10-13 12:40+09');
  perform tests.eq((r ->> 'confirmed_kcal')::numeric, 390.0, 'T13 값 유지 390');
  perform tests.ok(r -> 'flags' ? 'downward_edit', 'T13 downward_edit 플래그');
  -- 같은 내용 재전송 → unchanged
  r := confirm_meal(uid, m.id, jsonb_build_array(jsonb_build_object('chosen_name', '직접 입력', 'serving_kcal', 390, 'input_type', 'manual')), (r ->> 'version')::int, '2026-10-13 12:41+09');
  perform tests.ok((r ->> 'unchanged')::boolean, '동일 내용 재전송은 revision 없음');

  -- T19: 확정(10.12 09:00) 후 47h 수정 → 정정+이력, 49h → 거부
  select * into m from meals where participant_id = ji and local_date = '2026-10-12' and slot = 'lunch';
  update daily_scores set finalized_at = '2026-10-13 09:00+09' where participant_id = ji and local_date = '2026-10-12';
  perform tests.throws(format('select confirm_meal(%L, %L, %L::jsonb, %s, %L)', uid, m.id,
    jsonb_build_array(jsonb_build_object('chosen_name', '흰쌀밥', 'food_code', 'D000001'))::text, m.version, '2026-10-15 10:00+09'), 'PT422', 'T19 49h 수정 거부');
  r := confirm_meal(uid, m.id, jsonb_build_array(jsonb_build_object('chosen_name', '흰쌀밥', 'food_code', 'D000001')), m.version, '2026-10-15 08:00+09');
  perform tests.eq(r ->> 'status', 'corrected', 'T19 47h 수정 → 정정');
  perform tests.ok(exists (select 1 from score_revisions where participant_id = ji and reason = 'user_edit'), 'T19 정정 이력');
  perform tests.eq(participant_cumulative(ji), 341.1 + ((select s_d from daily_scores where participant_id = ji and local_date = '2026-10-12') - 41.2), 'T19 누적 차액 반영');
end $$;
rollback;

-- 건너뜀 한도·확정 배치 자동 확정
begin;
do $$
declare ji uuid := tests.pid('지수'); uid uuid := tests.uid('지수'); r jsonb;
begin
  delete from meals where participant_id = ji and local_date = '2026-10-13' and slot in ('breakfast', 'lunch');
  r := skip_meal(uid, ji, '2026-10-13', 'breakfast');
  perform tests.ok(not (r ->> 'over_limit')::boolean, '첫 건너뜀 허용');
  r := skip_meal(uid, ji, '2026-10-13', 'lunch');
  perform tests.ok((r ->> 'over_limit')::boolean, '같은 날 두 번째 건너뜀 → 초과');
  -- 골든 SKIP(전날 없음)은 120.3. 여기서는 전날(10.12) 점심 780 > M_p 742.5 라 한도 초과 점심 대체값이 780(D61) → 37.5 kcal 더 먹은 셈
  perform tests.eq((select (breakdown #>> '{intake,substitute_values,lunch}')::numeric from daily_scores where participant_id = ji and local_date = '2026-10-13'),
    780::numeric, '건너뜀 초과 점심 = 전날 점심 780');
  perform tests.eq((select s_d from daily_scores where participant_id = ji and local_date = '2026-10-13'), 112.8::numeric(5,1), '건너뜀 초과 골든 120.3 − 37.5/500×100 = 112.8');
  -- 09:00 확정: 초안 → max(M, 1.3×AI) 자동 확정, skip_abuse 플래그
  update meals set status = 'draft', ai_kcal = 850, confirmed_kcal = null where participant_id = ji and local_date = '2026-10-13' and slot = 'dinner';
  perform run_finalize('2026-10-14 09:00+09');
  perform tests.eq((select status::text || ':' || confirmed_kcal from meals where participant_id = ji and local_date = '2026-10-13' and slot = 'dinner'), 'auto:1105.0', 'T11 자동 확정 1,105');
  perform tests.ok((select is_final from daily_scores where participant_id = ji and local_date = '2026-10-13'), '10.13 확정');
  perform tests.ok(exists (select 1 from reviews where participant_id = ji and type = 'skip_abuse'), 'skip_abuse 플래그');
  perform tests.ok(exists (select 1 from leaderboard_snapshots where local_date = '2026-10-13' and is_final and scope = 'cumulative'), '확정 스냅샷');
end $$;
rollback;

-- 공동 순위 1-2-2-4 (T20)
begin;
do $$
declare ch uuid := (select id from challenges where invite_code = 'K7Q2MD'); snap jsonb;
begin
  delete from reviews; -- 집계 중 행 제거
  update daily_scores set s_d = 0 where local_date = '2026-10-13';
  update daily_scores set s_d = case (select nickname from participants where id = participant_id)
    when '강남콩' then 50 when '도토리' then 40 when '초록이' then 40 when '마포구민' then 30 else 0 end where local_date = '2026-10-13';
  perform build_leaderboard(ch, 'today', '2026-10-13', false, '2026-10-13 23:00+09');
  select rows into snap from leaderboard_snapshots where challenge_id = ch and scope = 'today' order by as_of desc limit 1;
  perform tests.eq((select string_agg(e ->> 'rank', ',') from (select e from jsonb_array_elements(snap) e limit 4) x), '1,2,2,4', 'T20 공동 순위 1-2-2-4');
  perform tests.ok((snap -> 1 ->> 'tie')::boolean, '동점 표시');
end $$;
rollback;

-- 생명주기·건강 신호·알림 큐
begin;
do $$
declare ch uuid := (select id from challenges where invite_code = 'K7Q2MD'); n int; v_new uuid;
begin
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('겨울 챌린지', 'draft', '2026-12-01', '2026-12-28', 30, (select operator_id from challenges where id = ch)) returning id into v_new;
  insert into challenge_rules (challenge_id) values (v_new);
  perform transition_challenge(v_new, 'recruiting');
  perform tests.ok((select invite_code ~ '^[A-Z2-9]{6}$' from challenges where id = v_new), '모집 전환 시 초대코드 발급');
  perform run_lifecycle('2026-12-01 00:00+09');
  perform tests.eq((select status::text from challenges where id = v_new), 'checking', '시작일 00:00 → Checking');
  perform tests.ok((select locked_at is not null from challenge_rules where challenge_id = v_new), 'Checking 진입 시 상수 잠금');
  perform run_lifecycle('2026-12-04 00:00+09');
  perform tests.eq((select status::text from challenges where id = v_new), 'running', '3일 뒤 Running');

  -- 건강 신호: 밤산책 10.9~10.11 섭취 < 1,200 3일 연속
  delete from health_alerts;
  n := run_health_check('2026-10-12 09:10+09');
  perform tests.ok(exists (select 1 from health_alerts where participant_id = tests.pid('밤산책') and type = 'low_intake_3d'), 'low_intake_3d 생성');
  perform tests.ok(exists (select 1 from notifications where user_id = tests.uid('밤산책') and type = 'N-07'), 'N-07 넛지');

  -- 알림 워커: 권한 없는 기기는 no_push, scheduled 하루 4건 상한
  update devices set push_permission = 'denied' where user_id = tests.uid('도토리');
  perform enqueue_notification(tests.uid('도토리'), ch, 'N-02', 't', '사진이 확정을 기다려요', '{}', '2026-10-13 21:00+09');
  for i in 1..5 loop perform enqueue_notification(tests.uid('초록이'), ch, 'N-03', 't', '공지', '{}', '2026-10-13 12:00+09'); end loop;
  perform count(*) from claim_due_notifications('2026-10-13 21:05+09');
  perform tests.eq((select skipped_reason from notifications where user_id = tests.uid('도토리') and type = 'N-02'), 'no_push', '푸시 권한 없음 → 인앱 배너 대체');
  perform tests.eq((select count(*)::int from notifications where user_id = tests.uid('초록이') and type = 'N-03' and sent_at is not null), 4, 'scheduled 하루 4건 상한');
end $$;
rollback;
