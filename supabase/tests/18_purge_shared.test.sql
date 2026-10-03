-- 공유 사진 파기(D52): 다른 챌린지가 아직 쓰는 사진은 남기고, 마지막 챌린지가 끝날 때 파기
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); seed uuid := (select id from challenges where invite_code = 'K7Q2MD');
  op2 uuid := '33333333-0000-4000-a000-000000000001';
  uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); x uuid; r jsonb; ph uuid; sha text := repeat('7b', 32);
begin
  insert into auth.users (id) values (op2);
  insert into users (id, provider, nickname, is_operator) values (op2, 'email', '두번째운영자', true);
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('공유 시험', 'running', '2026-10-01', '2026-10-31', 30, op2) returning id into x;
  insert into challenge_rules (challenge_id, locked_at) values (x, now());
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select x, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-10-01 09:00+09' from participants where id = ji;
  r := create_photo(uid, sha, 400000, 1568, 1176, '2026-10-13 12:30+09', '2026-10-13 12:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, sha, 400000, 1568, 1176, '2026-10-13 12:30+09');
  perform create_meal(uid, ph, false, '2026-10-13 12:31+09');

  update challenges set status = 'archived' where id = seed;
  perform tests.login(op);
  r := purge_challenge_photos(seed);
  perform tests.ok(not (r -> 'paths') ? (select storage_path from photos where id = ph), '다른 챌린지가 쓰는 사진은 남김');
  perform tests.ok((select purged_at is null from photos where id = ph), '공유 사진 파기 안 됨');
  perform tests.ok((r ->> 'count')::int > 0, '이 챌린지만 쓰던 사진은 파기');

  update challenges set status = 'archived' where id = x;
  perform tests.login(op2);
  r := purge_challenge_photos(x);
  perform tests.ok((r -> 'paths') ? (select storage_path from photos where id = ph), '마지막 챌린지가 끝나면 공유 사진 파기');
  perform tests.ok((select purged_at is not null from photos where id = ph), '파기 시각 기록');
end $$;

-- 복사본 챌린지 운영자도 공유 사진 행을 본다(대표 사진의 challenge_id 는 다른 챌린지)
select tests.login('33333333-0000-4000-a000-000000000001');
set local role authenticated;
do $$ begin
  perform tests.ok(exists (select 1 from photos where sha256 = repeat('7b', 32)), '복사본 챌린지 운영자도 공유 사진을 본다');
end $$;
reset role;
rollback;
