-- 걸음 출처(D72): 휴대폰 자체 센서(Health Connect 'com.android.healthconnect.phone.<기기값>')는 믿는 출처.
-- 허용 목록의 '.' 으로 끝나는 항목은 앞부분 일치로 본다. 미확인 출처 검토에는 출처별 걸음 수·첫/마지막 기록 시각을 남긴다.
begin;
do $$
declare hani uuid := tests.pid('달려라하니'); t jsonb;
begin
  perform tests.ok('com.android.healthconnect.phone.' = any ((engine_rules((select challenge_id from participants where id = hani))).origin_whitelist),
    '허용 목록에 휴대폰 센서 접두어');

  delete from reviews where participant_id = hani;
  perform ingest_activity_batch(hani, jsonb_build_object('client_batch_id', gen_random_uuid(), 'days', jsonb_build_array(
    jsonb_build_object('local_date', '2026-10-13', 'steps_total', 8000,
      'sources', jsonb_build_array(jsonb_build_object('origin', 'com.android.healthconnect.phone.j09d1bb81c', 'method', 'AUTOMATICALLY_RECORDED',
        'steps', 8000, 'first_at', '2026-10-13T07:10:00+09:00', 'last_at', '2026-10-13T21:40:00+09:00'))))), '2026-10-13 22:00+09');
  perform tests.ok(not exists (select 1 from reviews where participant_id = hani and type = 'source_unknown'), '휴대폰 센서 출처는 검토 없음');

  perform ingest_activity_batch(hani, jsonb_build_object('client_batch_id', gen_random_uuid(), 'days', jsonb_build_array(
    jsonb_build_object('local_date', '2026-10-13', 'steps_total', 9000,
      'sources', jsonb_build_array(jsonb_build_object('origin', 'com.unknown.stepfaker', 'method', 'AUTOMATICALLY_RECORDED',
        'steps', 1000, 'first_at', '2026-10-13T12:00:00+09:00', 'last_at', '2026-10-13T12:30:00+09:00'))))), '2026-10-13 22:05+09');
  select target into t from reviews where participant_id = hani and type = 'source_unknown' order by created_at desc limit 1;
  perform tests.eq(t ->> 'origin', 'com.unknown.stepfaker', '모르는 출처는 그대로 검토');
  perform tests.eq((t ->> 'steps')::int, 1000, '검토에 그 출처 걸음 수');
  perform tests.eq(t ->> 'first_at', '2026-10-13T12:00:00+09:00', '첫 기록 시각');
  perform tests.eq(t ->> 'last_at', '2026-10-13T12:30:00+09:00', '마지막 기록 시각');

  -- 접두어가 아닌 항목은 정확히 같아야 한다(com.sec.android.app.shealth.fake 는 미확인)
  perform tests.ok(not origin_trusted('com.sec.android.app.shealth.fake', array['com.sec.android.app.shealth']), '정확 일치 항목은 접두어로 보지 않음');
  perform tests.ok(origin_trusted('com.sec.android.app.shealth', array['com.sec.android.app.shealth']), '정확 일치');
end $$;
rollback;
