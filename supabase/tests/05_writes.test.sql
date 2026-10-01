-- 참가자 쓰기 경로: 사진 업로드·재검증, 끼니 생성(슬롯 태그·지연 업로드·중복 해시), 직접 입력, 신고, 계정 삭제
begin;
do $$
declare
  ji uuid := tests.pid('지수'); uid uuid := tests.uid('지수'); r jsonb; ph uuid; sha text := repeat('ab', 32); m uuid;
  rules challenge_rules := engine_rules((select challenge_id from participants where id = tests.pid('지수')));
begin
  -- 슬롯 경계(04 §4.3): 04:00 아침 · 10:30 점심 · 15:00 저녁 · 22:00 간식
  perform tests.eq(slot_for('2026-10-13 04:00+09', rules)::text, 'breakfast', '04:00 아침');
  perform tests.eq(slot_for('2026-10-13 03:59+09', rules)::text, 'snack', '03:59 간식');
  perform tests.eq(slot_for('2026-10-13 10:30+09', rules)::text, 'lunch', '10:30 점심');
  perform tests.eq(slot_for('2026-10-13 15:00+09', rules)::text, 'dinner', '15:00 저녁');
  perform tests.eq(slot_for('2026-10-13 22:00+09', rules)::text, 'snack', '22:00 간식');

  -- 사진 행 생성 검증
  perform tests.throws(format('select create_photo(%L, ''xyz'', 1000, 1568, 1176, now())', uid), 'PT422', 'sha256 형식');
  perform tests.throws(format('select create_photo(%L, %L, 1000, 3000, 2000, now())', uid, sha), 'PT422', '긴 변 1,568 px 초과 거부');
  r := create_photo(uid, sha, 412000, 1568, 1176, '2026-10-13 12:29+09', '2026-10-13 12:30+09');
  ph := (r ->> 'photo_id')::uuid;
  perform tests.ok(r ->> 'storage_path' like (select challenge_id from participants where id = ji)::text || '/' || ji || '/%.jpg', '저장 경로 = 챌린지/참가자/사진');
  perform tests.throws(format('select create_meal(%L, %L)', uid, ph), 'PT422', '재검증 전 끼니 생성 거부');
  perform tests.throws(format('select verify_photo(%L, %L, %L, 412000, 1568, 1176)', tests.uid('밤산책'), ph, sha), 'PT403', '남의 사진 검증 거부');

  -- 재검증 불일치 → photo_mismatch, verified false
  r := verify_photo(uid, ph, repeat('cd', 32), 412000, 1568, 1176, '2026-10-13 12:30+09');
  perform tests.ok(not (r ->> 'verified')::boolean, '해시 불일치 → 검증 실패');
  perform tests.ok(exists (select 1 from reviews where type = 'photo_mismatch' and target ->> 'photo_id' = ph::text), 'photo_mismatch 플래그');
  -- 정상 검증 → 끼니 생성(서버 12:30 → 점심, 국외 AI 동의 → gemini)
  r := verify_photo(uid, ph, sha, 412000, 1568, 1176, '2026-10-13 12:31+09');
  perform tests.ok((r ->> 'verified')::boolean, '재검증 통과');
  r := create_meal(uid, ph, false, '2026-10-13 12:31+09');
  m := (r ->> 'meal_id')::uuid;
  perform tests.eq(r ->> 'slot', 'lunch', '서버 KST 12:31 → 점심');
  perform tests.eq(r ->> 'engine', 'gemini', '국외 AI 동의자 → 분석 큐');
  perform tests.ok((r ->> 'analyze')::boolean and not (r ->> 'dup_photo')::boolean, '분석 요청·중복 아님');
  perform tests.ok((create_meal(uid, ph, false, '2026-10-13 12:32+09') ->> 'replayed')::boolean, '같은 사진 재요청 → 기존 끼니(멱등)');

  -- 중복 해시(본인·타인 사진과 같은 서버 해시) → dup_photo
  r := create_photo(uid, repeat('ef', 32), 1000, 1000, 800, null, '2026-10-13 12:40+09');
  update photos set sha256 = (select sha256_server from photos where participant_id = tests.pid('밤산책') limit 1) where id = (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, (r ->> 'photo_id')::uuid, (select sha256_server from photos where participant_id = tests.pid('밤산책') limit 1), 1000, 1000, 800);
  r := create_meal(uid, (r ->> 'photo_id')::uuid, false, '2026-10-13 12:41+09');
  perform tests.ok((r ->> 'dup_photo')::boolean, '타인 사진과 같은 해시 → dup_photo');
  perform tests.ok(exists (select 1 from reviews where type = 'dup_photo' and target ->> 'meal_id' = r ->> 'meal_id'), 'dup_photo 검토 생성');
end $$;
rollback;

-- 지연 업로드 규칙(05 §6, 03 F-MEAL-01)
begin;
do $$
declare uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); r jsonb; s_before numeric;
  function_photo jsonb;
begin
  s_before := (select s_d from daily_scores where participant_id = ji and local_date = '2026-10-12');
  -- 단말 날짜(10.12)가 이미 확정 → 끼니 미인정, 사진·해시만
  function_photo := create_photo(uid, repeat('11', 32), 1000, 1000, 800, '2026-10-12 19:00+09', '2026-10-13 12:30+09');
  perform verify_photo(uid, (function_photo ->> 'photo_id')::uuid, repeat('11', 32), 1000, 1000, 800);
  r := create_meal(uid, (function_photo ->> 'photo_id')::uuid, true, '2026-10-13 12:30+09');
  perform tests.eq(r ->> 'local_date', '2026-10-12', '확정일 지연 업로드: 단말 날짜로 보존');
  perform tests.ok(not (r ->> 'counted')::boolean and (r ->> 'late_upload')::boolean, '확정일 → 끼니 미인정 + late_upload');
  perform tests.eq((select s_d from daily_scores where participant_id = ji and local_date = '2026-10-12'), s_before, '확정 점수 불변');
  -- 30분 초과~12h, 미확정 날짜 → 단말 시각 태그(아침) + 플래그
  function_photo := create_photo(uid, repeat('22', 32), 1000, 1000, 800, '2026-10-13 07:40+09', '2026-10-13 09:00+09');
  perform verify_photo(uid, (function_photo ->> 'photo_id')::uuid, repeat('22', 32), 1000, 1000, 800);
  r := create_meal(uid, (function_photo ->> 'photo_id')::uuid, true, '2026-10-13 09:00+09');
  perform tests.eq(r ->> 'slot', 'breakfast', '80분 지연 → 단말 시각(07:40) 아침');
  perform tests.ok((r ->> 'late_upload')::boolean and (r ->> 'counted')::boolean, '지연 배지 + 인정');
  perform tests.ok(exists (select 1 from reviews where type = 'late_upload' and target ->> 'meal_id' = r ->> 'meal_id'), 'late_upload 플래그');
  -- 30분 이내 → 서버 시각, 플래그 없음
  function_photo := create_photo(uid, repeat('33', 32), 1000, 1000, 800, '2026-10-13 10:20+09', '2026-10-13 10:40+09');
  perform verify_photo(uid, (function_photo ->> 'photo_id')::uuid, repeat('33', 32), 1000, 1000, 800);
  r := create_meal(uid, (function_photo ->> 'photo_id')::uuid, true, '2026-10-13 10:40+09');
  perform tests.ok(r ->> 'slot' = 'lunch' and not (r ->> 'late_upload')::boolean, '20분 지연 → 서버 시각(10:40 점심), 플래그 없음');
  -- 12h 초과(미확정) → 서버 시각 + 플래그
  function_photo := create_photo(uid, repeat('44', 32), 1000, 1000, 800, '2026-10-13 00:30+09', '2026-10-13 13:00+09');
  perform verify_photo(uid, (function_photo ->> 'photo_id')::uuid, repeat('44', 32), 1000, 1000, 800);
  r := create_meal(uid, (function_photo ->> 'photo_id')::uuid, true, '2026-10-13 13:00+09');
  perform tests.ok(r ->> 'slot' = 'lunch' and (r ->> 'late_upload')::boolean, '12.5시간 지연 → 서버 시각 + 플래그');
  -- queued=false 면 단말 시각 무시
  function_photo := create_photo(uid, repeat('55', 32), 1000, 1000, 800, '2026-10-13 07:40+09', '2026-10-13 19:00+09');
  perform verify_photo(uid, (function_photo ->> 'photo_id')::uuid, repeat('55', 32), 1000, 1000, 800);
  r := create_meal(uid, (function_photo ->> 'photo_id')::uuid, false, '2026-10-13 19:00+09');
  perform tests.ok(r ->> 'slot' = 'dinner' and not (r ->> 'late_upload')::boolean, 'queued 아니면 서버 시각만');
  -- 국외 AI 미동의(오이냉국) → engine none, 분석 없음
  function_photo := create_photo(tests.uid('오이냉국'), repeat('66', 32), 1000, 1000, 800, null, '2026-10-13 19:00+09');
  perform verify_photo(tests.uid('오이냉국'), (function_photo ->> 'photo_id')::uuid, repeat('66', 32), 1000, 1000, 800);
  r := create_meal(tests.uid('오이냉국'), (function_photo ->> 'photo_id')::uuid, false, '2026-10-13 19:00+09');
  perform tests.ok(r ->> 'engine' = 'none' and not (r ->> 'analyze')::boolean, '국외 AI 미동의 → 검색 경로');
end $$;
rollback;

-- 직접 입력 끼니 (API #10)
begin;
do $$
declare uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); r jsonb;
begin
  r := create_manual_meal(uid, 'snack', '[{"chosen_name":"아메리카노","food_code":"D000084"}]', '2026-10-13', '2026-10-13 15:30+09');
  perform tests.eq((r ->> 'confirmed_kcal')::numeric, 10.0, '직접 입력: 식약처 1인분 kcal');
  perform tests.eq((select input_type::text from meal_items where meal_id = (r ->> 'meal_id')::uuid), 'manual', 'input_type manual');
  perform create_manual_meal(uid, 'snack', '[{"chosen_name":"바나나","serving_kcal":100,"input_type":"search"}]', null, '2026-10-13 16:00+09');
  r := create_manual_meal(uid, 'snack', '[{"chosen_name":"고구마","serving_kcal":220}]', null, '2026-10-13 16:30+09');
  perform tests.eq((r ->> 'manual_count_today')::int, 3, '직접 입력 3건');
  perform tests.ok(exists (select 1 from reviews where participant_id = ji and type = 'manual_input_burst'), '1일 3건 이상 → manual_input_burst');
  perform tests.ok(not (select under_review from daily_scores where participant_id = ji and local_date = '2026-10-13'), 'manual_input_burst 는 플래그(검토 중 아님)');
  perform tests.throws(format('select create_manual_meal(%L, ''lunch'', ''[{"chosen_name":"x","serving_kcal":100}]'', ''2026-10-12'', ''2026-10-13 16:00+09'')', uid), 'PT422', '확정된 날짜 입력 거부');
  perform tests.throws(format('select create_manual_meal(%L, ''lunch'', ''[]'', null, ''2026-10-13 16:00+09'')', uid), 'PT422', '빈 항목 거부');
end $$;
rollback;

-- 신고 (API #19)
begin;
do $$
declare
  dot uuid := tests.uid('도토리'); ji uuid := tests.pid('지수'); r jsonb; m uuid;
begin
  m := (select id from meals where participant_id = ji and local_date = '2026-10-13' and slot = 'lunch');
  r := submit_report(dot, null, m, '점심 사진이 메뉴판 같아요', '2026-10-13 14:00+09');
  perform tests.ok(exists (select 1 from reviews where id = (r ->> 'review_id')::uuid and type = 'report' and participant_id = ji
    and status = 'open' and local_date = '2026-10-13'), '신고 → 대상의 report 검토');
  perform tests.eq((select reporter_participant_id from review_reporters where review_id = (r ->> 'review_id')::uuid), tests.pid('도토리'), '신고자는 review_reporters 에만');
  perform tests.ok(not ((select to_jsonb(rv) from reviews rv where id = (r ->> 'review_id')::uuid)::text like '%' || tests.pid('도토리') || '%'), 'reviews 행에 신고자 없음');
  perform tests.ok(exists (select 1 from notifications where user_id = tests.uid('지수') and type = 'N-05' and body not like '%도토리%'), '대상에게 N-05(신고자 비노출)');
  perform tests.ok((select under_review from daily_scores where participant_id = ji and local_date = '2026-10-13'), '신고된 날 검토 중');
  perform tests.ok((submit_report(dot, null, m, '다시 신고', '2026-10-13 14:05+09') ->> 'replayed')::boolean, '같은 대상 중복 신고 → 기존 건');
  perform tests.throws(format('select submit_report(%L, %L, null, ''본인 신고'')', dot, tests.pid('도토리')), 'PT422', '본인 신고 불가');
  perform tests.throws(format('select submit_report(%L, %L, null, ''x'')', dot, ji), 'PT422', '사유 2자 미만 거부');
  perform submit_report(dot, tests.pid('강남콩'), null, '걸음이 이상해요', '2026-10-13 14:10+09');
  perform submit_report(dot, tests.pid('초록이'), null, '걸음이 이상해요', '2026-10-13 14:11+09');
  perform tests.throws(format('select submit_report(%L, %L, null, ''걸음이 이상해요'', ''2026-10-13 14:12+09'')', dot, tests.pid('마포구민')), 'PT429', '신고 하루 3건 상한');
end $$;
rollback;
-- 신고 대상은 소명할 수 있다
begin;
select set_config('tests.rid', (submit_report(tests.uid('도토리'), tests.pid('지수'), null, '걸음이 이상해요') ->> 'review_id'), true);
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$ begin
  insert into appeals (review_id, participant_id, text) values (current_setting('tests.rid')::uuid, tests.pid('지수'), '평소대로 걸었어요.');
  perform tests.ok(true, '신고 검토에 소명 가능');
end $$;
reset role;
rollback;

-- 계정 삭제 (API #22, 05 §8)
begin;
do $$
declare
  uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); r jsonb; n_photos int; ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
  cum_other numeric := participant_cumulative(tests.pid('강남콩')); s_kept numeric;
begin
  n_photos := (select count(*) from photos where participant_id = ji);
  s_kept := participant_cumulative(ji);
  perform tests.throws(format('select delete_account(%L, ''네'')', uid), 'PT422', '확인 문구 "삭제" 필요');
  perform tests.throws(format('select delete_account(%L, ''삭제'')', (select operator_id from challenges where id = ch)), 'PT409', '운영 중 챌린지가 있는 운영자는 삭제 불가');
  r := delete_account(uid, '삭제');
  perform tests.eq(jsonb_array_length(r -> 'storage_paths'), n_photos, 'Storage 삭제 대상 경로 반환');
  perform tests.eq((select count(*)::int from meals where participant_id = ji), 0, '식사 즉시 삭제');
  perform tests.eq((select count(*)::int from photos where participant_id = ji), 0, '사진 행 즉시 삭제');
  perform tests.eq((select count(*)::int from daily_activity where participant_id = ji), 0, '걸음 즉시 삭제');
  perform tests.eq((select count(*)::int from profiles where user_id = uid), 0, '프로필(기록 모드 사유 포함) 삭제');
  perform tests.eq((select count(*)::int from consents where user_id = uid) + (select count(*)::int from devices where user_id = uid)
    + (select count(*)::int from notifications where user_id = uid), 0, '동의·기기·알림 삭제');
  perform tests.eq((select nickname || ':' || status || ':' || coalesce(user_id::text, 'null') || ':' || coalesce(weight_locked::text, 'null')
    from participants where id = ji), '탈퇴 참가자:left:null:null', '참가자 익명화(신체 정보 제거)');
  perform tests.eq((select status || ':' || coalesce(nickname, 'null') from users where id = uid), 'deleted:null', 'users 익명화');
  perform tests.eq(participant_cumulative(ji), s_kept, '일별 점수 s_d 보존');
  perform tests.ok((select bool_and(bmr is null and i_d is null and breakdown = '{}') from daily_scores where participant_id = ji), '점수 분해값 제거');
  perform tests.ok(exists (select 1 from reviews where participant_id = ji), '판정 이력은 익명 participant_id 로 유지');
  update reviews set status = 'decided' where participant_id = ji; -- 검토 중이면 '집계 중' 행이라 이름 확인 불가
  perform build_leaderboard(ch, 'cumulative', '2026-10-13', false, '2026-10-13 23:59+09');
  perform tests.ok(exists (select 1 from leaderboard_snapshots s, jsonb_array_elements(s.rows) e
    where s.challenge_id = ch and s.as_of = '2026-10-13 23:59+09' and e ->> 'nickname' = '탈퇴 참가자'), '리더보드에 탈퇴 참가자(익명) 유지');
  perform tests.eq(participant_cumulative(tests.pid('강남콩')), cum_other, '타인 누적 불변');
  perform run_provisional('2026-10-13 23:00+09');
  perform tests.ok((select bool_and(bmr is null) from daily_scores where participant_id = ji), '배치가 탈퇴 참가자를 다시 계산하지 않음');
  update challenges set status = 'archived' where id = ch;
  perform tests.eq((select count(*)::int from daily_scores where participant_id = ji), 0, 'Archived → 탈퇴 참가자 점수 행 삭제');
end $$;
rollback;
