-- 사진 원본 자동 파기(D56): Archived·취소 즉시, 아니면 종료일+30일(상태 무관). 공유 사진은 쓰는 챌린지가 모두 파기 대상일 때.
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); seed uuid := (select id from challenges where invite_code = 'K7Q2MD');
  op2 uuid := '33333333-0000-4000-a000-000000000002';
  uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); x uuid; c uuid; cp uuid; r jsonb; ph uuid; own uuid; n_audit int;
  sha text := repeat('7c', 32); p_now1 timestamptz := '2026-10-16 03:30+09'; p_now2 timestamptz := '2026-12-01 03:30+09';
begin
  insert into auth.users (id) values (op2);
  insert into users (id, provider, nickname, is_operator) values (op2, 'email', '자동파기운영자', true);
  -- 진행 중인 다른 챌린지 X(종료 10-31): 지수의 끼니가 공유된다
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('자동 파기 진행', 'running', '2026-10-01', '2026-10-31', 30, op2) returning id into x;
  insert into challenge_rules (challenge_id, locked_at) values (x, now());
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select x, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-10-01 09:00+09' from participants where id = ji;
  r := create_photo(uid, sha, 400000, 1568, 1176, '2026-10-13 12:30+09', '2026-10-13 12:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, sha, 400000, 1568, 1176, '2026-10-13 12:30+09');
  perform create_meal(uid, ph, false, '2026-10-13 12:31+09');
  perform tests.ok(exists (select 1 from meals where photo_id = ph and challenge_id = x)
    and (exists (select 1 from meals where photo_id = ph and challenge_id = seed) or (select challenge_id from photos where id = ph) = seed),
    '공유 사진이 시드·X 둘 다에 걸림');

  -- 발표하지 않은 챌린지 C(closing, 종료 09-15 = p_now1 기준 31일 전): 자기 사진 1장
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('발표 안 한 월간', 'closing', '2026-09-01', '2026-09-15', 30, op2) returning id into c;
  insert into challenge_rules (challenge_id, locked_at) values (c, now());
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select c, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-09-01 09:00+09' from participants where id = ji
  returning id into cp;
  insert into photos (participant_id, challenge_id, storage_path, sha256) values (cp, c, 'auto-purge/c.jpg', repeat('7d', 32)) returning id into own;

  update challenges set status = 'archived' where id = seed;
  perform tests.ok(exists (select 1 from photos where challenge_id = seed and purged_at is null and id <> ph), '시드에 파기 전 사진이 있음');

  -- 1회차(10-16): 시드(Archived)·C(종료+31일) 파기, X(진행 중) 남김, 공유 사진 남김
  r := purge_due_photos(p_now1);
  perform tests.ok((r ->> 'count')::int > 0, '자동 파기 건수 > 0');
  perform tests.eq((r ->> 'count')::int, jsonb_array_length(r -> 'paths'), 'count = paths 수');
  perform tests.ok(not exists (select 1 from photos where challenge_id = seed and purged_at is null and id <> ph), 'Archived 챌린지 사진 파기');
  perform tests.ok((select purged_at is not null from photos where id = own), '종료+31일 closing 챌린지 사진 파기');
  perform tests.ok((r -> 'paths') ? 'auto-purge/c.jpg', 'C 경로 반환');
  perform tests.ok((select photos_purged_at is not null from challenges where id = c), 'C photos_purged_at 기록');
  perform tests.ok((select photos_purged_at is null from challenges where id = x), '진행 중 챌린지는 파기 안 함');
  perform tests.ok((select purged_at is null from photos where id = ph), '진행 중 챌린지와 공유한 사진은 남김');
  perform tests.ok(not (r -> 'paths') ? (select storage_path from photos where id = ph), '공유 사진 경로 반환 안 함');
  perform tests.ok(exists (select 1 from audit_logs where challenge_id = seed and action = 'purge_photos' and actor_role = 'system' and actor_id is null),
    '시스템 감사 로그');

  -- 2회차(같은 날): 0건, 감사 로그 추가 없음
  select count(*) into n_audit from audit_logs where action = 'purge_photos';
  r := purge_due_photos(p_now1);
  perform tests.eq((r ->> 'count')::int, 0, '두 번째 실행은 0건');
  perform tests.eq(jsonb_array_length(r -> 'paths'), 0, '두 번째 실행 경로 없음');
  perform tests.eq((select count(*)::int from audit_logs where action = 'purge_photos'), n_audit, '0건이면 감사 로그 없음');

  -- 3회차(12-01): X 종료+31일 → 공유 사진 파기(상태는 running 그대로)
  r := purge_due_photos(p_now2);
  perform tests.ok((r -> 'paths') ? (select storage_path from photos where id = ph), 'X 종료+30일 지나면 공유 사진 파기');
  perform tests.ok((select purged_at is not null from photos where id = ph), '공유 사진 purged_at 기록');
  perform tests.ok((select photos_purged_at is not null from challenges where id = x), 'X photos_purged_at 기록');
  r := purge_due_photos(p_now2);
  perform tests.eq((r ->> 'count')::int, 0, '다시 돌리면 0건');
end $$;

-- 운영자 RPC: Archived·종료+30일은 파기, 진행 중은 PT422
do $$
declare op2 uuid := '33333333-0000-4000-a000-000000000002'; ji uuid := tests.pid('지수'); a uuid; e uuid; z uuid; ap uuid; r jsonb;
begin
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('운영자 파기 Archived', 'archived', '2026-09-01', '2026-09-30', 30, op2) returning id into a;
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select a, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-09-01 09:00+09' from participants where id = ji
  returning id into ap;
  insert into photos (participant_id, challenge_id, storage_path, sha256) values (ap, a, 'auto-purge/a.jpg', repeat('7e', 32));
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('운영자 파기 종료+31', 'closing', kst_date() - 60, kst_date() - 31, 30, op2) returning id into e;
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('운영자 파기 진행', 'running', kst_date(), kst_date() + 30, 30, op2) returning id into z;

  perform tests.login(op2);
  r := purge_challenge_photos(a);
  perform tests.eq((r ->> 'count')::int, 1, '운영자 RPC: Archived 파기');
  perform tests.ok((r -> 'paths') ? 'auto-purge/a.jpg', '운영자 RPC: 경로 반환');
  perform tests.ok(exists (select 1 from audit_logs where challenge_id = a and action = 'purge_photos' and actor_id = op2 and actor_role = 'operator'),
    '운영자 감사 로그');
  r := purge_challenge_photos(e);
  perform tests.eq((r ->> 'count')::int, 0, '운영자 RPC: 종료+30일 지난 챌린지도 파기 가능');
  perform tests.ok(exists (select 1 from audit_logs where challenge_id = e and action = 'purge_photos' and actor_role = 'operator'),
    '운영자 호출은 0건이어도 감사 로그');
  perform tests.throws(format('select purge_challenge_photos(%L)', z), 'PT422', '운영자 RPC: 진행 중은 거절', '종료(Archived) 뒤에 파기할 수 있어요');
end $$;

-- 권한: 자동 파기·내부 함수는 service_role 만
do $$ begin
  perform tests.ok(not has_function_privilege('authenticated', 'purge_due_photos(timestamptz)', 'execute'), 'authenticated 는 purge_due_photos 불가');
  perform tests.ok(not has_function_privilege('anon', 'purge_due_photos(timestamptz)', 'execute'), 'anon 은 purge_due_photos 불가');
  perform tests.ok(has_function_privilege('service_role', 'purge_due_photos(timestamptz)', 'execute'), 'service_role 은 purge_due_photos 가능');
  perform tests.ok(not has_function_privilege('authenticated', 'purge_photos_core(uuid, uuid, text, date)', 'execute'), 'authenticated 는 core 불가');
  perform tests.ok(not has_function_privilege('authenticated', 'photo_purge_eligible(challenges, date)', 'execute'), 'authenticated 는 eligible 불가');
  perform tests.ok(has_function_privilege('authenticated', 'purge_challenge_photos(uuid)', 'execute'), '운영자 RPC 권한 유지');
end $$;
rollback;
