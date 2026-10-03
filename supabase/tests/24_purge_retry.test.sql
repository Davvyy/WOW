-- 사진 파기 재시도: Storage 삭제가 실패한 경로는 unmark_photos_purged 로 purged_at 을 되돌리고,
-- 다음 purge_due_photos 가 다시 돌려준다(Edge purge-due·meal-delete).
begin;
do $$
declare op2 uuid := '33333333-0000-4000-a000-000000000024'; ji uuid := tests.pid('지수');
  a uuid; ap uuid; x uuid; xp uuid; r jsonb; n int;
  p_now1 timestamptz := '2026-10-16 03:30+09'; p_now2 timestamptz := '2026-12-01 03:30+09';
begin
  insert into auth.users (id) values (op2);
  insert into users (id, provider, nickname, is_operator) values (op2, 'email', '재시도운영자', true);
  -- Archived 챌린지 A: 사진 2장
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('재시도 Archived', 'archived', '2026-09-01', '2026-09-30', 30, op2) returning id into a;
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select a, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-09-01 09:00+09' from participants where id = ji
  returning id into ap;
  insert into photos (participant_id, challenge_id, storage_path, sha256) values
    (ap, a, 'retry/a1.jpg', repeat('24', 32)), (ap, a, 'retry/a2.jpg', repeat('25', 32));

  r := purge_due_photos(p_now1);
  perform tests.ok((r -> 'paths') ? 'retry/a1.jpg' and (r -> 'paths') ? 'retry/a2.jpg', '1회차: 두 경로 반환');
  perform tests.eq((select count(*)::int from photos where challenge_id = a and purged_at is not null), 2, '1회차: purged_at 기록');

  -- Storage 삭제가 a1 만 실패했다고 보고 되돌린다
  n := unmark_photos_purged(array['retry/a1.jpg', 'retry/none.jpg']);
  perform tests.eq(n, 1, '되돌린 사진 수(없는 경로는 무시)');
  perform tests.ok((select purged_at is null from photos where storage_path = 'retry/a1.jpg'), 'a1 purged_at 되돌림');
  perform tests.ok((select purged_at is not null from photos where storage_path = 'retry/a2.jpg'), 'a2 는 그대로');
  perform tests.eq(unmark_photos_purged(array['retry/a1.jpg']), 0, '이미 되돌린 경로는 0건');

  -- 2회차: 실패한 경로만 다시 나온다
  r := purge_due_photos(p_now1);
  perform tests.ok((r -> 'paths') ? 'retry/a1.jpg', '2회차: 실패한 경로 다시 반환');
  perform tests.ok(not (r -> 'paths') ? 'retry/a2.jpg', '2회차: 지운 경로는 다시 안 나옴');
  perform tests.ok((select purged_at is not null from photos where storage_path = 'retry/a1.jpg'), '2회차: a1 purged_at 다시 기록');

  -- 진행 중 챌린지 X 의 지운 끼니 사진(delete_meal 이 purged_at 기록 후 Storage 실패): 되돌리면 X 가 파기 대상이 될 때 나온다
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('재시도 진행', 'running', '2026-10-01', '2026-10-31', 30, op2) returning id into x;
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select x, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-10-01 09:00+09' from participants where id = ji
  returning id into xp;
  insert into photos (participant_id, challenge_id, storage_path, sha256, purged_at) values (xp, x, 'retry/x1.jpg', repeat('26', 32), p_now1);
  perform tests.eq(unmark_photos_purged(array['retry/x1.jpg']), 1, '지운 끼니 사진 되돌림');
  r := purge_due_photos(p_now1);
  perform tests.ok(not (r -> 'paths') ? 'retry/x1.jpg', '진행 중 챌린지: 아직 파기 대상 아님');
  r := purge_due_photos(p_now2);
  perform tests.ok((r -> 'paths') ? 'retry/x1.jpg', '종료+30일 지나면 다시 반환');
end $$;

-- 권한: service_role 만
do $$ begin
  perform tests.ok(not has_function_privilege('authenticated', 'unmark_photos_purged(text[])', 'execute'), 'authenticated 는 unmark 불가');
  perform tests.ok(not has_function_privilege('anon', 'unmark_photos_purged(text[])', 'execute'), 'anon 은 unmark 불가');
  perform tests.ok(has_function_privilege('service_role', 'unmark_photos_purged(text[])', 'execute'), 'service_role 은 unmark 가능');
end $$;
rollback;
