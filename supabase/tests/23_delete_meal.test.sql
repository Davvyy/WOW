-- 끼니 기록 삭제(docs/02 D57): 참가자가 확정 전 날짜의 자기 대표 끼니를 지운다. 복사본까지 같이 지우고 점수 재계산,
-- 다른 끼니가 쓰지 않는 사진 원본은 바로 파기(경로를 돌려주면 Edge 가 Storage 에서 지운다). 확인 중(열린 검토)인 기록은 지우지 않는다.
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD');
  seed uuid := (select id from challenges where invite_code = 'K7Q2MD');
  uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); x uuid; xp uuid; r jsonb; ph uuid; m uuid; cp uuid;
  m2 uuid; cp2 uuid; m3 uuid; rv_own uuid; rv_copy uuid; v_slot text; i_ji numeric; i_xp numeric; n_items int;
  items jsonb := '[{"chosen_name":"비빔밥","serving_kcal":560,"eaten":true}]';
  t_del timestamptz := '2026-10-13 13:00+09';
begin
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('삭제 시험', 'running', '2026-10-01', '2026-10-31', 30, op) returning id into x;
  insert into challenge_rules (challenge_id, locked_at) values (x, now());
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select x, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-10-01 09:00+09'
  from participants where id = ji returning id into xp;

  -- 사진 끼니(대표 = 시드 챌린지, 복사본 = X) 확정
  r := create_photo(uid, repeat('5a', 32), 400000, 1568, 1176, '2026-10-13 12:30+09', '2026-10-13 12:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('5a', 32), 400000, 1568, 1176, '2026-10-13 12:30+09');
  m := (create_meal(uid, ph, false, '2026-10-13 12:31+09') ->> 'meal_id')::uuid;
  perform confirm_meal(uid, m, items, (select version from meals where id = m), '2026-10-13 12:40+09');
  cp := (select id from meals where record_group_id = m and id <> m);
  perform tests.ok(cp is not null and (select participant_id from meals where id = cp) = xp, '복사본이 X 에 있음');

  -- 확인 중인 기록은 지울 수 없다: 복사본에 열린 플래그(다른 사진 끼니), 대표에 소명 중(appealed) 신고(직접 넣은 끼니)
  r := create_photo(uid, repeat('5c', 32), 400000, 1568, 1176, '2026-10-13 12:50+09', '2026-10-13 12:50+09');
  perform verify_photo(uid, (r ->> 'photo_id')::uuid, repeat('5c', 32), 400000, 1568, 1176, '2026-10-13 12:50+09');
  m2 := (create_meal(uid, (r ->> 'photo_id')::uuid, false, '2026-10-13 12:51+09') ->> 'meal_id')::uuid;
  cp2 := (select id from meals where record_group_id = m2 and id <> m2);
  rv_copy := raise_flag(xp, '2026-10-13', 'dup_photo', jsonb_build_object('key', cp2::text, 'meal_id', cp2), '2026-10-13 12:52+09');
  perform tests.throws(format('select delete_meal(%L, %L)', uid, m2), 'PT422', '복사본이 확인 중', '확인 중인 기록은 지울 수 없어요');
  insert into meals (participant_id, challenge_id, local_date, slot, status, confirmed_kcal) values (ji, seed, '2026-10-13', 'snack', 'confirmed', 200)
  returning id into m3;
  insert into reviews (challenge_id, participant_id, type, local_date, target, status)
  values (seed, ji, 'report', '2026-10-13', jsonb_build_object('meal_id', m3, 'slot', 'snack'), 'appealed') returning id into rv_own;
  perform tests.throws(format('select delete_meal(%L, %L)', uid, m3), 'PT422', '대표가 확인 중(소명)', '확인 중인 기록은 지울 수 없어요');
  perform tests.ok((select count(*) = 2 from meals where record_group_id = m2) and exists (select 1 from meals where id = m3), '확인 중인 끼니는 남음');
  perform tests.ok((select status = 'open' and verdict is null and decided_at is null from reviews where id = rv_copy)
    and (select status = 'appealed' and verdict is null and decided_at is null from reviews where id = rv_own), '검토는 그대로(판정되지 않음)');

  -- 삭제 전 섭취(위에서 직접 넣은 끼니까지 반영해 두고 비교)
  perform recompute_day(ji, '2026-10-13'); perform recompute_day(xp, '2026-10-13');
  select i_d into i_ji from daily_scores where participant_id = ji and local_date = '2026-10-13';
  select i_d into i_xp from daily_scores where participant_id = xp and local_date = '2026-10-13';
  perform tests.ok(i_ji is not null and i_xp is not null, '두 참가자 모두 점수 행');

  -- 복사본 id·없는 id → PT404, 남의 끼니 → PT403
  perform tests.throws(format('select delete_meal(%L, %L)', uid, cp), 'PT404', '복사본 id 는 찾지 못함', '기록을 찾지 못했어요');
  perform tests.throws(format('select delete_meal(%L, %L)', uid, gen_random_uuid()), 'PT404', '없는 끼니', '기록을 찾지 못했어요');
  perform tests.throws(format('select delete_meal(%L, %L)', tests.uid('강남콩'), m), 'PT403', '다른 사용자', '내 기록만 지울 수 있어요');

  -- 삭제: 대표 + 복사본, 항목 cascade, 두 참가자 재계산
  v_slot := (select slot::text from meals where id = m);
  r := delete_meal(uid, m, t_del);
  perform tests.eq(r ->> 'meal_id', m::text, '응답 meal_id');
  perform tests.eq((r ->> 'deleted')::int, 2, '대표 + 복사본 2건 삭제');
  perform tests.eq(r ->> 'local_date', '2026-10-13', '응답 local_date');
  perform tests.eq(r ->> 'slot', v_slot, '응답 slot');
  perform tests.ok(not exists (select 1 from meals where record_group_id = m), '그룹 전체 삭제');
  select count(*) into n_items from meal_items where meal_id in (m, cp);
  perform tests.eq(n_items, 0, '항목 cascade');
  perform tests.ok((select i_d from daily_scores where participant_id = ji and local_date = '2026-10-13') is distinct from i_ji, '대표 참가자 섭취 재계산');
  perform tests.ok((select i_d from daily_scores where participant_id = xp and local_date = '2026-10-13') is distinct from i_xp, '복사본 참가자 섭취 재계산');

  -- 사진: 다른 끼니가 쓰지 않으면 파기 경로 반환
  perform tests.eq(r ->> 'purge_path', (select storage_path from photos where id = ph), '안 쓰는 사진은 purge_path 반환');
  perform tests.eq((select purged_at from photos where id = ph), t_del, '사진 purged_at 기록');

  -- 감사 로그
  perform tests.ok(exists (select 1 from audit_logs where challenge_id = seed and actor_id = uid and actor_role = 'participant'
    and action = 'meal_delete' and target ->> 'meal_id' = m::text and target ->> 'local_date' = '2026-10-13'
    and (target ->> 'copies')::int = 1 and target ? 'slot'), '감사 로그');

  -- 같은 끼니 다시 삭제 → PT404
  perform tests.throws(format('select delete_meal(%L, %L)', uid, m), 'PT404', '이미 지운 끼니', '기록을 찾지 못했어요');
end $$;

-- 사진을 다른 끼니가 쓰면 파기하지 않는다
do $$
declare uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수');
  op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD'); y uuid; yp uuid; r jsonb; ph uuid; m uuid;
begin
  r := create_photo(uid, repeat('5b', 32), 400000, 1568, 1176, '2026-10-13 15:00+09', '2026-10-13 15:00+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, repeat('5b', 32), 400000, 1568, 1176, '2026-10-13 15:00+09');
  m := (create_meal(uid, ph, false, '2026-10-13 15:01+09') ->> 'meal_id')::uuid;
  -- 같은 사진을 쓰는 다른 그룹의 끼니(끼니·사진 유니크는 참가자별이라 다른 참가로 만든다. 공유 복사본이 생기지 않게 끼니를 만든 뒤 참가)
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('삭제 시험 Y', 'running', '2026-10-01', '2026-10-31', 30, op) returning id into y;
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select y, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-10-01 09:00+09'
  from participants where id = ji returning id into yp;
  insert into meals (participant_id, challenge_id, local_date, slot, status, photo_id) values (yp, y, '2026-10-13', 'snack', 'captured', ph);
  r := delete_meal(uid, m, '2026-10-13 15:10+09');
  perform tests.ok(r ? 'purge_path' and r -> 'purge_path' = 'null'::jsonb, '다른 끼니가 쓰는 사진: purge_path null');
  perform tests.ok((select purged_at is null from photos where id = ph), '다른 끼니가 쓰는 사진은 남김');
end $$;

-- 확정된 날짜·판정된 기록은 지울 수 없다
do $$
declare uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); seed uuid := (select id from challenges where invite_code = 'K7Q2MD');
  fm uuid; vm uuid; dm uuid;
begin
  select id into fm from meals where participant_id = ji and local_date = '2026-10-12' and record_group_id = id limit 1;
  perform tests.ok((select is_final from daily_scores where participant_id = ji and local_date = '2026-10-12'), '10-12 는 확정된 날');
  perform tests.throws(format('select delete_meal(%L, %L)', uid, fm), 'PT422', '확정된 날짜', '확정된 날짜의 기록은 지울 수 없어요');

  insert into meals (participant_id, challenge_id, local_date, slot, status, confirmed_kcal) values (ji, seed, '2026-10-13', 'snack', 'void', 300)
  returning id into vm;
  perform tests.throws(format('select delete_meal(%L, %L)', uid, vm), 'PT422', '무효 판정 끼니', '판정된 기록은 지울 수 없어요');

  insert into meals (participant_id, challenge_id, local_date, slot, status, confirmed_kcal) values (ji, seed, '2026-10-13', 'snack', 'confirmed', 300)
  returning id into dm;
  insert into reviews (challenge_id, participant_id, type, local_date, target, status, verdict, decided_at)
  values (seed, ji, 'downward_edit', '2026-10-13', jsonb_build_object('key', dm::text, 'meal_id', dm), 'decided', 'warn', now());
  perform tests.throws(format('select delete_meal(%L, %L)', uid, dm), 'PT422', '판정 끝난 검토가 있는 끼니', '판정된 기록은 지울 수 없어요');
  perform tests.ok(exists (select 1 from meals where id in (fm, vm, dm) having count(*) = 3), '거절된 끼니는 남음');
end $$;

-- 권한: service_role 만(Edge meal-delete)
do $$ begin
  perform tests.ok(not has_function_privilege('authenticated', 'delete_meal(uuid, uuid, timestamptz)', 'execute'), 'authenticated 는 delete_meal 불가');
  perform tests.ok(not has_function_privilege('anon', 'delete_meal(uuid, uuid, timestamptz)', 'execute'), 'anon 은 delete_meal 불가');
  perform tests.ok(has_function_privilege('service_role', 'delete_meal(uuid, uuid, timestamptz)', 'execute'), 'service_role 은 delete_meal 가능');
end $$;
rollback;
