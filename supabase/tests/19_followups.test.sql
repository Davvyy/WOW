-- 겹치는 챌린지 경계(D47·D52): 대표 끼니는 그 날짜를 품는 참가, closing 은 3개 제한 밖, 월간 생성 오류에도 배치 진행,
-- 이미 참가 중이면 마감 후에도 다시 참가, 본인의 상태 변경은 participant 로 감사.
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD');
  a uuid; b uuid; pa uuid; pb uuid; u uuid; r jsonb; ph uuid; m uuid; sha text := repeat('7b', 32);
  items jsonb := '[{"chosen_name":"비빔밥","serving_kcal":560,"eaten":true}]';
begin
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('경계 A', 'running', '2026-10-01', '2026-10-31', 30, op) returning id into a;
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('경계 B', 'running', '2026-11-01', '2026-11-30', 30, op) returning id into b;
  insert into challenge_rules (challenge_id, locked_at) values (a, now()), (b, now());
  pa := tests.new_participant(a, '경계참가', '2026-10-01 09:00+09'); u := (select user_id from participants where id = pa);
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select b, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-11-01 00:00+09'
  from participants where id = pa returning id into pb;

  -- 직접 입력: 가장 최근 참가(B)는 10-31 을 품지 않음 → 그 날짜를 품는 A 가 대표
  r := create_manual_meal(u, 'dinner', items, '2026-10-31', '2026-11-01 08:00+09');
  perform tests.eq((select participant_id from meals where id = (r ->> 'meal_id')::uuid), pa, '직접 입력: 날짜를 품는 참가(A)가 대표');
  perform tests.ok(not exists (select 1 from meals where participant_id = pb), '직접 입력: 기간 밖 B 에는 복사본 없음');

  -- 사진 끼니: 사진은 B 아래 저장, 늦은 업로드로 10-31 태그 → 대표는 A, B 에는 복사본 없음
  r := create_photo(u, sha, 400000, 1568, 1176, '2026-10-31 20:00+09', '2026-11-01 07:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform tests.eq((select participant_id from photos where id = ph), pb, '사진은 가장 최근 참가(B) 아래');
  perform verify_photo(u, ph, sha, 400000, 1568, 1176, '2026-11-01 07:30+09');
  r := create_meal(u, ph, true, '2026-11-01 07:30+09'); m := (r ->> 'meal_id')::uuid;
  perform tests.eq(r ->> 'local_date', '2026-10-31', '늦은 업로드: 촬영일(10-31)로 태그');
  perform tests.eq((select participant_id from meals where id = m), pa, '사진 끼니: 날짜를 품는 참가(A)가 대표');
  perform tests.ok((select record_group_id = id from meals where id = m), '대표 끼니');
  perform tests.ok(not exists (select 1 from meals where photo_id = ph and participant_id = pb), '사진 끼니: 기간 밖 B 에는 복사본 없음');
  r := create_meal(u, ph, true, '2026-11-01 07:31+09');
  perform tests.ok((r ->> 'replayed')::boolean and (r ->> 'meal_id')::uuid = m, '재요청 → 다른 참가의 대표 끼니를 돌려줌(멱등)');
  perform tests.eq((select count(*)::int from meals where photo_id = ph), 1, '재요청해도 끼니가 늘지 않음');
  perform tests.throws(format('select create_meal(%L, %L, true, %L)', gen_random_uuid(), ph, '2026-11-01 07:32+09'), 'PT403', '다른 사용자는 사진 사용 불가');
end $$;
rollback;

-- closing 은 동시 3개 제한에 세지 않는다(F3)
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); t date := kst_date();
  c1 uuid; c2 uuid; c3 uuid; p1 uuid;
begin
  insert into challenges (name, status, start_date, end_date, capacity, operator_id) values ('제한 1', 'running', t - 5, t + 20, 30, op)
  returning id into c1;
  insert into challenges (name, status, start_date, end_date, capacity, operator_id) values ('제한 2', 'running', t - 5, t + 20, 30, op)
  returning id into c2;
  insert into challenges (name, status, start_date, end_date, capacity, operator_id) values ('제한 3', 'closing', t - 30, t - 1, 30, op)
  returning id into c3;
  insert into challenges (name, status, start_date, end_date, capacity, invite_code, operator_id, join_open)
  values ('제한 4', 'running', t - 1, t + 28, 30, 'FUPCAP', op, true);
  insert into challenge_rules (challenge_id, locked_at) select id, now() from challenges where name like '제한 _';
  p1 := tests.new_participant(c1, '제한참가', now() - interval '5 days');
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select c, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, now() - interval '5 days'
  from participants, unnest(array[c2, c3]) c where id = p1;
  perform tests.login((select user_id from participants where id = p1));
end $$;
set local role authenticated;
do $$
declare r jsonb;
begin
  r := join_challenge('{"code":"FUPCAP","nickname":"제한참가","sex":"F","birth_year":1990,"height_cm":160,"weight_kg":55,
    "consents":{"terms":true,"sensitive_health":true}}'::jsonb);
  perform tests.ok(r ? 'participant_id', 'closing 챌린지는 3개 제한에 세지 않음 → 4번째 참가');
end $$;
reset role;
rollback;

-- 월간 챌린지 생성에 오류가 나도 생명주기 배치는 계속(F4)
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); c uuid;
begin
  insert into app_settings (key, value) values ('monthly_operator_id', to_jsonb('00000000-0000-4000-a000-0000000000ff'::uuid))
  on conflict (key) do update set value = excluded.value;
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('배치 시험', 'recruiting', '2027-01-25', '2027-02-24', 30, op) returning id into c;
  insert into challenge_rules (challenge_id) values (c);
  perform run_lifecycle('2027-02-01 00:00+09');
  perform tests.eq((select status::text from challenges where id = c), 'checking', '월간 생성 오류에도 모집 → 점검 전환');
  perform tests.ok(not exists (select 1 from challenges where kind = 'monthly' and start_date = '2027-02-01'), '월간 챌린지는 건너뜀');
end $$;
rollback;

-- 이미 참가 중이면 참가 마감 뒤에도 같은 참가를 돌려준다(F5)
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); t date := kst_date(); c uuid; p uuid;
begin
  insert into challenges (name, status, start_date, end_date, capacity, invite_code, operator_id, join_open)
  values ('재참가 시험', 'running', t - 5, t + 20, 30, 'FUPRE5', op, true) returning id into c;
  insert into challenge_rules (challenge_id, locked_at) values (c, now());
  p := tests.new_participant(c, '재참가', now() - interval '5 days');
  update challenges set join_open = false where id = c;
  perform tests.login((select user_id from participants where id = p));
end $$;
set local role authenticated;
do $$
declare r jsonb;
begin
  r := join_challenge('{"code":"FUPRE5","nickname":"재참가2","sex":"F","birth_year":1990,"height_cm":160,"weight_kg":55,
    "consents":{"terms":true,"sensitive_health":true}}'::jsonb);
  perform tests.eq((r ->> 'participant_id')::uuid, tests.pid('재참가2'), '참가 마감 뒤 재요청 → 기존 참가(닉네임 갱신)');
  perform tests.ok(r ? 'check_start' and r ? 'bmr' and r ? 'm_p' and r ? 'f_p' and r ? 'record_mode' and r ->> 'kind' = 'operator',
    '같은 응답 형태');
end $$;
reset role;
rollback;

-- 본인이 나가면 감사 로그 역할은 participant(F6)
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); t date := kst_date(); c uuid; p uuid;
begin
  insert into challenges (id, name, status, start_date, end_date, capacity, operator_id)
  values ('11111111-0000-4000-a000-0000000000f6', '감사 시험', 'running', t - 5, t + 20, 30, op) returning id into c;
  insert into challenge_rules (challenge_id, locked_at) values (c, now());
  p := tests.new_participant(c, '감사참가', now() - interval '5 days');
  perform tests.login((select user_id from participants where id = p));
end $$;
set local role authenticated;
select leave_challenge('11111111-0000-4000-a000-0000000000f6');
reset role;
do $$ begin
  perform tests.eq((select actor_role from audit_logs where action = 'participant_status'
    and target ->> 'participant_id' = tests.pid('감사참가')::text), 'participant', '본인 나가기 → actor_role participant');
end $$;
rollback;
