-- 참가 전 날짜 점수 행 금지(중간 참가, D48): 동기화가 최근 3일을 보내도 check_start 이전 행을 만들지 않는다
begin;
do $$
declare ch uuid := (select id from challenges where invite_code = 'K7Q2MD'); p uuid; r daily_scores;
  b jsonb;
begin
  p := tests.new_participant(ch, '늦참가', '2026-10-12 09:00+09');
  perform tests.eq((select check_start from participants where id = p), '2026-10-12'::date, '참가일 = check_start');

  b := jsonb_build_object('client_batch_id', gen_random_uuid(), 'tz', 'Asia/Seoul', 'days', jsonb_build_array(
    jsonb_build_object('local_date', '2026-10-10', 'steps_total', 4000, 'sources', '[{"origin":"com.sec.android.app.shealth"}]'::jsonb),
    jsonb_build_object('local_date', '2026-10-11', 'steps_total', 5000, 'sources', '[{"origin":"com.sec.android.app.shealth"}]'::jsonb),
    jsonb_build_object('local_date', '2026-10-12', 'steps_total', 6000, 'sources', '[{"origin":"com.sec.android.app.shealth"}]'::jsonb),
    jsonb_build_object('local_date', '2026-10-13', 'steps_total', 7000, 'sources', '[{"origin":"com.sec.android.app.shealth"}]'::jsonb)));
  perform ingest_activity_batch(p, b, '2026-10-13 21:00+09');

  perform tests.eq((select count(*)::int from daily_scores where participant_id = p and local_date < '2026-10-12'), 0, '참가 전 날짜 점수 행 없음');
  perform tests.ok(exists (select 1 from daily_scores where participant_id = p and local_date = '2026-10-12'), '참가일 점수 행 있음');
  perform tests.ok(exists (select 1 from daily_scores where participant_id = p and local_date = '2026-10-13'), '참가 후 날짜 점수 행 있음');

  r := compute_daily_score(p, '2026-10-11');
  perform tests.ok(r is null, '참가 전 날짜 compute_daily_score → null');
  perform tests.eq((select count(*)::int from daily_scores where participant_id = p and local_date = '2026-10-11'), 0, 'compute 후에도 행 없음');
  perform tests.ok(recompute_day(p, '2026-10-11') is null, 'recompute_day 도 null');
  r := compute_daily_score(p, '2026-10-12');
  perform tests.eq(r.local_date, '2026-10-12'::date, '참가일 compute_daily_score 정상');
end $$;
rollback;
