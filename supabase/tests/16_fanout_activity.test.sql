-- 걸음·운동 기록 공유(D52): 같은 배치가 참가 중인 모든 챌린지에, 재전송은 멱등
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); ji uuid := tests.pid('지수');
  x uuid; xp uuid; bid uuid := gen_random_uuid(); b jsonb; r jsonb;
begin
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('공유 시험', 'running', '2026-10-01', '2026-10-31', 30, op) returning id into x;
  insert into challenge_rules (challenge_id, locked_at) values (x, now());
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select x, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-10-01 09:00+09'
  from participants where id = ji returning id into xp;

  b := jsonb_build_object('client_batch_id', bid, 'tz', 'Asia/Seoul', 'days', jsonb_build_array(
    jsonb_build_object('local_date', '2026-10-13', 'steps_total', 9100, 'sources', '[{"origin":"com.sec.android.app.shealth"}]'::jsonb)));
  r := ingest_activity_batch(ji, b, '2026-10-13 21:00+09');
  perform tests.ok(r ? 'days', '대표 참가 결과 반환');
  perform tests.eq((select steps_total from daily_activity where participant_id = xp and local_date = '2026-10-13'), 9100, '공유 챌린지에도 같은 걸음');
  perform tests.ok(exists (select 1 from daily_scores where participant_id = xp and local_date = '2026-10-13'), '공유 챌린지 점수 계산');
  perform tests.eq((select count(*)::int from sync_batches where participant_id in (ji, xp)
    and client_batch_id in (bid, md5(bid::text || ':' || xp)::uuid)), 2, '참가별 배치 기록');
  r := ingest_activity_batch(ji, b, '2026-10-13 21:05+09');
  perform tests.ok((r ->> 'replayed')::boolean, '같은 배치 재전송 → 저장된 결과');
  perform tests.eq((select count(*)::int from daily_activity where participant_id = xp and local_date = '2026-10-13'), 1, '재전송해도 1행');
end $$;
rollback;
