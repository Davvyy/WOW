-- 푸시 기기 등록 · 트랜잭션 알림(N-04) 즉시 집기
begin;
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
declare d1 uuid; d2 uuid;
begin
  d1 := register_device(null, 'android', 'tok-A', 'granted', '1.0.0');
  perform tests.ok(d1 is not null, '기기 등록');
  d2 := register_device(d1, 'android', 'tok-B', 'granted', null);
  perform tests.eq(d2, d1, '토큰 갱신은 같은 행');
  perform tests.eq((select push_token from devices where id = d1), 'tok-B', '새 토큰 저장');
  perform tests.eq((select app_version from devices where id = d1), '1.0.0', '버전 생략 시 유지');
  perform tests.throws('select register_device(null, ''web'', ''x'', ''granted'')', 'PT422', '플랫폼 검사');
  perform tests.throws('select * from claim_notification(gen_random_uuid())', '42501', '참가자는 알림 집기 불가');
end $$;
reset role;
-- 같은 기기에서 다른 계정으로 로그인 → 이전 계정 행의 같은 토큰은 지움
select tests.login(tests.uid('밤산책'));
set local role authenticated;
do $$ begin perform register_device(null, 'ios', 'tok-B', 'granted'); end $$;
reset role;
do $$
declare
  jisu uuid := tests.uid('지수'); night uuid := tests.uid('밤산책');
  ch uuid := (select id from challenges where invite_code = 'K7Q2MD');
  n uuid; cnt int; toks text[];
begin
  perform tests.ok(not exists (select 1 from devices where user_id = jisu and push_token = 'tok-B'), '토큰 중복 제거(한 기기 한 계정)');
  n := enqueue_notification(night, ch, 'N-04', '분석 완료', '점심 분석이 끝났어요. 확인하고 확정해 주세요', jsonb_build_object('meal_id', gen_random_uuid()));
  select count(*), max(push_tokens::text) into cnt from claim_notification(n);
  perform tests.eq(cnt, 1, 'N-04 바로 집기');
  perform tests.ok((select sent_at is not null from notifications where id = n), '보냄 표시');
  perform tests.eq((select count(*)::int from claim_notification(n)), 0, '두 번 집지 않음');
  -- 토큰 없는 사용자: 발송 생략(no_push) → 앱 인앱 갱신으로 대체
  delete from devices where user_id = jisu;
  n := enqueue_notification(jisu, ch, 'N-04', '분석 완료', '저녁 분석이 끝났어요.', '{}');
  perform tests.eq((select count(*)::int from claim_notification(n)), 0, '토큰 없음 → 발송 안 함');
  perform tests.eq((select skipped_reason from notifications where id = n), 'no_push', 'no_push 기록');
  -- N-05(scheduled): 22~08시 생성분은 08:00 예약 → 바로 보내기(claim_notification)로도 집히지 않음
  n := enqueue_notification(night, ch, 'N-05', '기록 확인 안내', '기록을 확인 중이에요. 72시간 안에 설명을 남길 수 있어요',
    jsonb_build_object('review_id', gen_random_uuid()), '2026-10-13 23:30+09');
  perform tests.eq((select count(*)::int from claim_notification(n, '2026-10-13 23:31+09')), 0, 'N-05 밤 생성분은 바로 안 보냄');
  perform tests.eq((select count(*)::int from claim_notification(n, '2026-10-14 08:00+09')), 1, 'N-05 08:00 에 보냄');
  n := enqueue_notification(night, ch, 'N-05', '기록 확인 안내', '기록을 확인 중이에요.', '{}', '2026-10-13 12:00+09');
  perform tests.eq((select scheduled_at from notifications where id = n), '2026-10-13 12:00+09'::timestamptz, 'N-05 낮 생성분은 즉시 예약');
  select array_agg(t) into toks from claim_due_notifications(now(), 200) c, unnest(c.push_tokens) t;
  perform tests.ok(toks is null or not ('tok-A' = any(toks)), '지워진 토큰으로는 안 보냄');
end $$;
rollback;
