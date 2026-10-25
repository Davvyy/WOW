-- 설정 토글 서버 저장(docs/02 D75): my_settings · set_my_settings, 알림 끄기(muted), 순위 공개·배지(참가 행 전부·새 참가 이어받기),
-- AI 분석 동의 철회·재동의(분석 전 끼니는 분석 안 함), 세션의 이번 주 건너뜀 사용 수.
begin;
-- 기본값: 알림 모두 켬 · 순위 공개 · 배지 비공개 · 시드의 AI 동의
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare s jsonb := my_settings();
begin
  perform tests.eq(s ->> 'notify_yesterday', 'true', '기본 어제 결과 켬');
  perform tests.eq(s ->> 'notify_reminder', 'true', '기본 저녁 리마인드 켬');
  perform tests.eq(s ->> 'notify_analysis', 'true', '기본 분석 완료 켬');
  perform tests.eq(s ->> 'leaderboard_visible', 'true', '기본 순위 공개');
  perform tests.eq(s ->> 'grade_badge_public', 'false', '기본 배지 비공개');
  perform tests.eq(s ->> 'ai_consent', 'true', '시드: AI 동의');
  perform tests.throws($q$select set_my_settings('{"is_operator": true}')$q$, 'PT422', '모르는 키는 거절');
  perform tests.throws($q$select set_my_settings('{"notify_reminder": "no"}')$q$, 'PT422', '불리언이 아니면 거절');
  s := set_my_settings('{"notify_analysis": false, "notify_yesterday": false, "leaderboard_visible": false, "grade_badge_public": true}');
  perform tests.eq(s ->> 'notify_analysis', 'false', '분석 완료 끔');
  perform tests.eq(s ->> 'notify_yesterday', 'false', '어제 결과 끔');
  perform tests.eq(s ->> 'notify_reminder', 'true', '안 보낸 키는 그대로');
  perform tests.eq(s ->> 'leaderboard_visible', 'false', '순위 숨김');
  perform tests.eq(s ->> 'grade_badge_public', 'true', '배지 공개');
  perform tests.eq((my_settings() ->> 'notify_analysis'), 'false', '다시 읽어도 유지');
end $$;
reset role;
do $$
declare jisu uuid := tests.uid('지수');
begin
  perform tests.ok(not exists (select 1 from participants where user_id = jisu and (leaderboard_visible or not grade_badge_public)),
    '내 참가 행 전부에 공개 설정 반영');
end $$;
-- 순위표: 숨긴 사람은 다른 사람 목록에 없음(기존 build_leaderboard 규칙)
do $$
declare ch uuid := (select challenge_id from participants where id = tests.pid('지수')); rows jsonb; sid uuid;
begin
  sid := build_leaderboard(ch, 'cumulative', '2026-10-13', false, '2026-10-13 23:59+09');
  select s.rows into rows from leaderboard_snapshots s where s.id = sid;
  perform tests.ok(jsonb_array_length(rows) > 0, '순위표 행 있음');
  perform tests.ok(not exists (select 1 from jsonb_array_elements(rows) e where e ->> 'participant_id' = tests.pid('지수')::text),
    '숨긴 참가자는 순위표 행에 없음');
end $$;
-- 알림: 끈 종류(N-01·N-04)는 muted, 켠 종류(N-02)·끌 수 없는 종류(N-03)는 보냄
do $$
declare
  jisu uuid := tests.uid('지수');
  ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
  n4 uuid; n1 uuid; n2 uuid; n3 uuid;
begin
  delete from devices where user_id = jisu;
  insert into devices (user_id, platform, push_token, push_permission) values (jisu, 'android', 'tok-set', 'granted');
  n4 := enqueue_notification(jisu, ch, 'N-04', '분석 완료', '점심 분석이 끝났어요.', '{}');
  perform tests.eq((select count(*)::int from claim_notification(n4)), 0, 'N-04 끔 → 안 보냄');
  perform tests.eq((select skipped_reason from notifications where id = n4), 'muted', 'N-04 muted 기록');
  n1 := enqueue_notification(jisu, ch, 'N-01', '어제 결과', '어제 30.0점', '{}', '2026-10-14 09:30+09');
  n2 := enqueue_notification(jisu, ch, 'N-02', '동기화', '앱을 열면 걸음이 동기화돼요', '{}', '2026-10-14 12:00+09');
  n3 := enqueue_notification(jisu, ch, 'N-03', '공지', '공지 본문', '{}', '2026-10-14 12:00+09');
  perform tests.eq((select count(*)::int from claim_notification(n1, '2026-10-14 12:01+09')), 0, 'N-01 끔 → 안 보냄');
  perform tests.eq((select skipped_reason from notifications where id = n1), 'muted', 'N-01 muted 기록');
  perform tests.eq((select count(*)::int from claim_notification(n2, '2026-10-14 12:01+09')), 1, 'N-02 켬 → 보냄');
  perform tests.eq((select count(*)::int from claim_notification(n3, '2026-10-14 12:01+09')), 1, 'N-03 은 끌 수 없음 → 보냄');
end $$;
-- 저녁 리마인드도 끄면 안 보냄
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$ begin perform set_my_settings('{"notify_reminder": false}'); end $$;
reset role;
do $$
declare jisu uuid := tests.uid('지수'); ch uuid := (select challenge_id from participants where id = tests.pid('지수')); n uuid;
begin
  n := enqueue_notification(jisu, ch, 'N-02', '동기화', '앱을 열면 걸음이 동기화돼요', '{}', '2026-10-14 12:00+09');
  perform tests.eq((select count(*)::int from claim_notification(n, '2026-10-14 12:01+09')), 0, 'N-02 끔 → 안 보냄');
  perform tests.eq((select skipped_reason from notifications where id = n), 'muted', 'N-02 muted 기록');
end $$;
-- AI 동의 철회: 동의 행 철회 · 분석 전(captured) 끼니는 engine none · 확정된 끼니는 그대로
do $$
declare ji uuid := tests.pid('지수'); ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
begin
  insert into meals (participant_id, challenge_id, local_date, slot, status, engine) values
    (ji, ch, '2026-10-13', 'snack', 'captured', 'gemini'),
    (ji, ch, '2026-10-12', 'snack', 'draft', 'gemini');
end $$;
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare s jsonb;
begin
  s := set_my_settings('{"ai_consent": false}');
  perform tests.eq(s ->> 'ai_consent', 'false', '철회됨');
end $$;
reset role;
do $$
declare jisu uuid := tests.uid('지수'); ji uuid := tests.pid('지수');
begin
  perform tests.ok(not exists (select 1 from consents where user_id = jisu and type = 'overseas_ai' and revoked_at is null), '동의 행 철회');
  perform tests.ok(exists (select 1 from consents where user_id = jisu and type = 'overseas_ai' and revoked_at is not null), '철회 이력 남음');
  perform tests.eq((select engine::text from meals where participant_id = ji and local_date = '2026-10-13' and slot = 'snack' and status = 'captured'),
    'none', '분석 전 끼니는 분석 안 함');
  perform tests.eq((select engine::text from meals where participant_id = ji and local_date = '2026-10-12' and slot = 'snack' and status = 'draft'),
    'gemini', '분석 끝난 끼니는 그대로');
end $$;
-- 재동의: 새 동의 행 하나(두 번 눌러도 하나)
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare s jsonb;
begin
  s := set_my_settings('{"ai_consent": true}');
  s := set_my_settings('{"ai_consent": true}');
  perform tests.eq(s ->> 'ai_consent', 'true', '다시 동의');
end $$;
reset role;
do $$
declare jisu uuid := tests.uid('지수');
begin
  perform tests.eq((select count(*)::int from consents where user_id = jisu and type = 'overseas_ai' and revoked_at is null), 1, '활성 동의 1건');
  perform tests.eq((select version from consents where user_id = jisu and type = 'overseas_ai' and revoked_at is null), 'v1', '이전 동의 버전');
end $$;
-- 새로 참가하는 행은 내 공개 설정을 이어받는다
do $$
declare jisu uuid := tests.uid('지수'); c2 uuid; v participants;
begin
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
    values ('설정 이어받기', 'recruiting', '2026-11-01', '2026-11-30', 10, (select id from users where is_operator limit 1))
    returning id into c2;
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked)
    values (c2, jisu, '지수2', 'M', 1996, 30, 175, 70, 1650)
    returning * into v;
  perform tests.ok(v.id is not null, '두 번째 참가 행 준비');
  perform tests.ok(not v.leaderboard_visible, '새 참가 행: 순위 숨김 이어받음');
  perform tests.ok(v.grade_badge_public, '새 참가 행: 배지 공개 이어받음');
end $$;
-- 남의 설정은 못 바꾸고, 로그인 없이는 못 부름
do $$
begin
  perform tests.ok(not has_function_privilege('anon', 'set_my_settings(jsonb)', 'execute'), '익명은 못 부름');
  perform tests.ok(has_function_privilege('authenticated', 'my_settings()', 'execute'), '앱 사용자는 읽기 가능');
end $$;
select tests.login(tests.uid('밤산책'));
set local role authenticated;
do $$
begin
  perform tests.eq(my_settings() ->> 'leaderboard_visible', 'true', '다른 사용자 설정은 따로');
end $$;
reset role;
-- 세션: 이번 주 오늘 전 건너뜀 사용 수(서버 점수 계산과 같은 함수)
do $$
declare ji uuid := tests.pid('지수'); ch uuid := (select challenge_id from participants where id = tests.pid('지수'));
  monday date := date_trunc('week', kst_date())::date; s jsonb;
begin
  delete from meals where participant_id = ji and status = 'skipped' and local_date >= monday;
  if kst_date() > monday then
    insert into meals (participant_id, challenge_id, local_date, slot, status) values (ji, ch, monday, 'breakfast', 'skipped');
  end if;
  insert into meals (participant_id, challenge_id, local_date, slot, status) values (ji, ch, kst_date(), 'lunch', 'skipped'); -- 오늘 건 제외
  perform tests.login(tests.uid('지수'));
  s := challenge_session(ch);
  perform tests.eq((s ->> 'skips_used_this_week')::int, case when kst_date() > monday then 1 else 0 end, '세션: 이번 주 오늘 전 건너뜀 수');
  perform tests.eq((s ->> 'skips_used_this_week')::int, skips_used_before(ji, kst_date(), engine_rules(ch)), '서버 계산과 같음');
end $$;
rollback;
