-- 끼니 기록 공유(D52): 한 번 올리면 참가 중인 모든 챌린지에. 분석·확정·건너뜀·직접 입력이 그룹 전체에 반영되고,
-- 참가자에게는 대표 끼니만 보인다.
begin;
do $$
declare op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD');
  uid uuid := tests.uid('지수'); ji uuid := tests.pid('지수'); x uuid; xp uuid; r jsonb; ph uuid; m uuid; cp meals; sha text := repeat('9a', 32);
  items jsonb := '[{"chosen_name":"비빔밥","serving_kcal":560,"eaten":true}]';
begin
  insert into challenges (name, status, start_date, end_date, capacity, operator_id)
  values ('공유 시험', 'running', '2026-10-01', '2026-10-31', 30, op) returning id into x;
  insert into challenge_rules (challenge_id, locked_at) values (x, now());
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  select x, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, '2026-10-01 09:00+09'
  from participants where id = ji returning id into xp;

  -- 사진 끼니: 대표는 가장 최근 참가(시드 챌린지), 공유 챌린지에 복사본
  r := create_photo(uid, sha, 400000, 1568, 1176, '2026-10-13 12:30+09', '2026-10-13 12:30+09'); ph := (r ->> 'photo_id')::uuid;
  perform verify_photo(uid, ph, sha, 400000, 1568, 1176, '2026-10-13 12:30+09');
  r := create_meal(uid, ph, false, '2026-10-13 12:31+09'); m := (r ->> 'meal_id')::uuid;
  perform tests.eq((select participant_id from meals where id = m), ji, '대표 끼니 = 가장 최근 참가');
  select * into cp from meals where record_group_id = m and participant_id = xp;
  perform tests.ok(cp.id is not null and cp.photo_id = ph and cp.status = 'captured' and cp.slot = 'lunch', '공유 챌린지에 같은 사진의 복사본');
  perform tests.ok((create_meal(uid, ph, false, '2026-10-13 12:32+09') ->> 'replayed')::boolean, '같은 사진 재요청 → 대표 끼니(멱등)');
  perform tests.eq((select count(*)::int from meals where photo_id = ph), 2, '재요청해도 복사본이 늘지 않음');

  -- 분석 결과(Edge analyze-meal 이 항목 insert 후 status·ai_kcal 갱신) → 복사본에 전파
  insert into meal_items (meal_id, chosen_name, name_candidates, ai_kcal, serving_kcal) values (m, '비빔밥', '{비빔밥}', 560, 560);
  update meals set status = 'draft', ai_kcal = 560, engine = 'gemini' where id = m;
  select * into cp from meals where id = cp.id;
  perform tests.ok(cp.status = 'draft' and cp.ai_kcal = 560, '분석 결과가 복사본에 전파');
  perform tests.eq((select count(*)::int from meal_items where meal_id = cp.id), 1, '초안 항목도 복사');

  -- 확정 → 복사본도 같은 항목으로 확정·점수 재계산
  perform confirm_meal(uid, m, items, (select version from meals where id = m), '2026-10-13 12:40+09');
  select * into cp from meals where id = cp.id;
  perform tests.ok(cp.status = 'confirmed' and cp.confirmed_kcal = 560, '확정이 복사본에 반영');
  perform tests.ok(exists (select 1 from daily_scores where participant_id = xp and local_date = '2026-10-13'), '공유 챌린지 점수 재계산');

  -- 복사본 확정이 실패해 남은 경우: 같은 내용을 다시 보내면 복사본이 복구된다
  update meals set status = 'draft', confirmed_kcal = null where id = cp.id;
  perform confirm_meal(uid, m, items, (select version from meals where id = m), '2026-10-13 12:45+09');
  select * into cp from meals where id = cp.id;
  perform tests.ok(cp.status = 'confirmed' and cp.confirmed_kcal = 560, '같은 내용 재전송으로 복사본 복구');

  -- 건너뜀·직접 입력도 그룹으로
  perform skip_meal(uid, ji, '2026-10-13', 'breakfast', '2026-10-13 13:00+09');
  perform tests.ok(exists (select 1 from meals where participant_id = xp and local_date = '2026-10-13' and slot = 'breakfast' and status = 'skipped'
    and record_group_id <> id), '건너뜀 복사본');
  r := create_manual_meal(uid, 'dinner', items, '2026-10-13', '2026-10-13 19:00+09');
  perform tests.ok(exists (select 1 from meals where participant_id = xp and slot = 'dinner' and local_date = '2026-10-13'
    and status = 'confirmed' and record_group_id = (r ->> 'meal_id')::uuid), '직접 입력 복사본 확정');
end $$;
-- 참가자에게는 대표 끼니만
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$ begin
  perform tests.eq((select count(*)::int from meals where local_date = '2026-10-13' and record_group_id <> id), 0, '참가자: 복사본은 보이지 않음');
  perform tests.ok((select count(*) from meals where local_date = '2026-10-13') > 0, '참가자: 대표 끼니는 보임');
end $$;
reset role;
rollback;
