-- 닉네임 바꾸기(docs/02 D81): set_my_nickname · join_challenge 의 길이(2~12자)·같은 챌린지 중복(대소문자 무시) 규칙.
-- 바꾸면 users 와 진행 중(모집·점검·진행·마감) 챌린지의 내 참가 행이 같이 바뀐다. 지난 순위 스냅샷은 그대로.
begin;
do $$
declare
  op uuid := (select operator_id from challenges where invite_code = 'K7Q2MD');
  t date := kst_date();
  a uuid := '45450000-0000-4000-a000-0000000000a1';  -- 나·밥·추방된이
  b uuid := '45450000-0000-4000-a000-0000000000b1';  -- 나·고양이
  c uuid := '45450000-0000-4000-a000-0000000000c1';  -- 지난 챌린지(발표 끝): 나
  d uuid := '45450000-0000-4000-a000-0000000000d1';  -- 나는 없음: 다른방
  me uuid := '45450000-0000-4000-a000-000000000001';
  bob uuid := '45450000-0000-4000-a000-000000000002';
  cat uuid := '45450000-0000-4000-a000-000000000003';
  dan uuid := '45450000-0000-4000-a000-000000000004';
  eve uuid := '45450000-0000-4000-a000-000000000005';
  x record;
begin
  insert into challenges (id, name, status, start_date, end_date, capacity, invite_code, operator_id, join_open) values
    (a, '닉네임 A', 'running', t - 5, t + 20, 30, 'NICKA1', op, true),
    (b, '닉네임 B', 'running', t - 5, t + 20, 30, 'NICKB2', op, true),
    (c, '닉네임 지난', 'published', t - 60, t - 30, 30, 'NICKC3', op, false),
    (d, '닉네임 D', 'running', t - 5, t + 20, 30, 'NICKD4', op, true);
  insert into challenge_rules (challenge_id, locked_at) select id, now() from challenges where id in (a, b, c, d);
  insert into auth.users (id) values (me), (bob), (cat), (dan), (eve);
  insert into users (id, provider, nickname) values (me, 'kakao', '옛이름'), (bob, 'kakao', 'Bobby'), (cat, 'kakao', '고양이'),
    (dan, 'kakao', '추방된이'), (eve, 'kakao', '다른방');
  for x in select * from (values (a, me, '옛이름', 'active'), (b, me, '옛이름', 'active'), (c, me, '옛이름', 'active'),
      (a, bob, 'Bobby', 'active'), (a, dan, '추방된이', 'kicked'), (b, cat, '고양이', 'active'), (d, eve, '다른방', 'active'))
      v(ch, u, nick, st) loop
    insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, status, joined_at)
    values (x.ch, x.u, x.nick, 'F', 1990, 36, 160, 55, bmr_kcal('F', 55, 160, 36), x.st::participant_status, now() - interval '3 days');
  end loop;
  -- 바꾸기 전 순위 스냅샷(지난 스냅샷은 다시 쓰지 않는다)
  perform build_leaderboard(a, 'today', t, false, now() - interval '1 hour');
end $$;

-- 권한: authenticated 만 부를 수 있다. anon 은 못 부르고, 로그인 없이는 401. 내부 함수는 직접 못 부른다.
do $$ begin
  perform tests.ok(has_function_privilege('authenticated', 'set_my_nickname(text)', 'execute'), 'authenticated 는 set_my_nickname 실행 가능');
  perform tests.ok(not has_function_privilege('anon', 'set_my_nickname(text)', 'execute'), 'anon 은 set_my_nickname 실행 불가');
  perform tests.ok(not has_function_privilege('authenticated', 'nickname_normalize(text)', 'execute'), '정리 함수는 직접 못 부름');
  perform tests.ok(not has_function_privilege('authenticated', 'nickname_taken(uuid, text, uuid)', 'execute'), '중복 확인 함수는 직접 못 부름');
end $$;
set local role anon;
do $$ begin
  perform tests.throws($q$select set_my_nickname('익명이')$q$, '42501', 'anon 은 호출 불가');
end $$;
reset role;
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
do $$ begin
  perform tests.throws($q$select set_my_nickname('누구게')$q$, 'PT401', '로그인 없으면 401');
end $$;
reset role;

-- 바꾸기: 앞뒤 공백을 지우고 users · 진행 중 챌린지의 내 참가 행을 바꾼다
select tests.login('45450000-0000-4000-a000-000000000001');
set local role authenticated;
do $$
declare r jsonb;
begin
  r := set_my_nickname('  새이름  ');
  perform tests.eq(r, '{"nickname": "새이름"}'::jsonb, '성공하면 {nickname} (앞뒤 공백 지움)');
  perform tests.throws($q$update participants set nickname = '직접' where user_id = auth.uid()$q$, '42501', '참가 행 닉네임을 직접 바꿀 수 없음(서버 함수로만)');
end $$;
reset role;
do $$
declare me uuid := '45450000-0000-4000-a000-000000000001';
begin
  perform tests.eq((select nickname from users where id = me), '새이름', 'users.nickname 바뀜');
  perform tests.eq((select nickname from participants where user_id = me and challenge_id = '45450000-0000-4000-a000-0000000000a1'), '새이름', '챌린지 A 참가 행 바뀜');
  perform tests.eq((select nickname from participants where user_id = me and challenge_id = '45450000-0000-4000-a000-0000000000b1'), '새이름', '챌린지 B 참가 행 바뀜');
  perform tests.eq((select nickname from participants where user_id = me and challenge_id = '45450000-0000-4000-a000-0000000000c1'), '옛이름', '지난(발표 끝) 챌린지 참가 행은 그대로');
  perform tests.ok(exists (select 1 from leaderboard_snapshots s, jsonb_array_elements(s.rows) e
    where s.challenge_id = '45450000-0000-4000-a000-0000000000a1' and e ->> 'nickname' = '옛이름'), '지난 순위 스냅샷은 그대로');
end $$;

-- 길이: 앞뒤 공백을 뺀 2~12자(글자 수)
select tests.login('45450000-0000-4000-a000-000000000001');
set local role authenticated;
do $$
declare r jsonb;
begin
  perform tests.throws($q$select set_my_nickname('가')$q$, 'PT422', '1자는 거절', '%2~12자%');
  perform tests.throws($q$select set_my_nickname('   가   ')$q$, 'PT422', '공백을 빼면 1자 → 거절', '닉네임은 2~12자로 정해 주세요');
  perform tests.throws($q$select set_my_nickname('    ')$q$, 'PT422', '공백만 → 거절');
  perform tests.throws($q$select set_my_nickname(null)$q$, 'PT422', 'null → 거절');
  perform tests.throws($q$select set_my_nickname('가나다라마바사아자차카타파')$q$, 'PT422', '13자는 거절', '%2~12자%');
  r := set_my_nickname('가나다라마바사아자차카타');
  perform tests.eq(r ->> 'nickname', '가나다라마바사아자차카타', '한글 12자 허용');
  r := set_my_nickname('ab');
  perform tests.eq(r ->> 'nickname', 'ab', '2자 허용');

  -- 같은 챌린지 중복: 대소문자·앞뒤 공백 무시
  perform tests.throws($q$select set_my_nickname('Bobby')$q$, 'PT409', '같은 챌린지(A)에 있는 닉네임 거절', '이미 같은 챌린지에 있는 닉네임이에요');
  perform tests.throws($q$select set_my_nickname(' bOBBY ')$q$, 'PT409', '대소문자가 달라도 거절');
  perform tests.throws($q$select set_my_nickname('고양이')$q$, 'PT409', '다른 참가 챌린지(B)의 닉네임도 거절');
  perform tests.eq((select nickname from users where id = auth.uid()), 'ab', '거절되면 그대로');
  -- 내가 없는 챌린지의 닉네임 · 강퇴된 참가자의 닉네임은 쓸 수 있다
  r := set_my_nickname('다른방');
  perform tests.eq(r ->> 'nickname', '다른방', '다른 챌린지(D)에만 있는 닉네임은 허용');
  r := set_my_nickname('추방된이');
  perform tests.eq(r ->> 'nickname', '추방된이', '강퇴된 참가자의 닉네임은 허용');
  -- 내 지금 닉네임(대소문자만 다른 것 포함)으로 다시 저장해도 된다
  r := set_my_nickname('Mine');
  r := set_my_nickname('Mine');
  perform tests.eq(r ->> 'nickname', 'Mine', '지금 닉네임 그대로 저장 허용');
  r := set_my_nickname('MINE');
  perform tests.eq(r ->> 'nickname', 'MINE', '내 닉네임의 대소문자만 바꾸기 허용');
end $$;
reset role;

-- 참가(join_challenge)도 같은 길이·중복 규칙(참가하려는 챌린지 기준)
do $$ begin
  insert into auth.users (id) values ('45450000-0000-4000-a000-000000000006');
end $$;
select tests.login('45450000-0000-4000-a000-000000000006');
set local role authenticated;
do $$
declare r jsonb; j text := '"sex":"F","birth_year":1990,"height_cm":160,"weight_kg":55,"consents":{"terms":true,"sensitive_health":true}';
begin
  perform tests.throws(format('select join_challenge(''{"code":"NICKA1","nickname":"가",%s}'')', j), 'PT422', '참가: 1자 닉네임 거절', '%2~12자%');
  perform tests.throws(format('select join_challenge(''{"code":"NICKA1","nickname":"가나다라마바사아자차카타파",%s}'')', j), 'PT422', '참가: 13자 닉네임 거절');
  perform tests.throws(format('select join_challenge(''{"code":"NICKA1",%s}'')', j), 'PT422', '참가: 닉네임 없으면 거절');
  perform tests.throws(format('select join_challenge(''{"code":"NICKA1","nickname":"bobby",%s}'')', j), 'PT409', '참가: 그 챌린지에 있는 닉네임 거절(대소문자 무시)', '이미 같은 챌린지에 있는 닉네임이에요');
  perform tests.throws(format('select join_challenge(''{"code":"NICKA1","nickname":"mine",%s}'')', j), 'PT409', '참가: 방금 바꾼 닉네임과도 겹치면 거절');
  r := join_challenge(format('{"code":"NICKA1","nickname":"  고양이 ",%s}', j)::jsonb);
  perform tests.ok(r ? 'participant_id', '참가: 다른 챌린지(B)에만 있는 닉네임은 허용');
  perform tests.eq((select nickname from participants where id = (r ->> 'participant_id')::uuid), '고양이', '참가: 앞뒤 공백 지워 저장');
  perform tests.eq((select nickname from users where id = auth.uid()), '고양이', '참가: users 도 같은 닉네임');
  -- 다시 참가(멱등): 내 닉네임 그대로는 허용, 남의 닉네임으로 바꾸려면 거절
  r := join_challenge(format('{"code":"NICKA1","nickname":"고양이",%s}', j)::jsonb);
  perform tests.ok(r ? 'participant_id', '다시 참가: 내 닉네임 그대로 허용');
  perform tests.throws(format('select join_challenge(''{"code":"NICKA1","nickname":"BOBBY",%s}'')', j), 'PT409', '다시 참가: 남의 닉네임으로는 거절');
  perform tests.throws(format('select join_challenge(''{"code":"NICKA1","nickname":"x",%s}'')', j), 'PT422', '다시 참가: 길이 규칙');
  perform tests.eq((select nickname from participants where id = (r ->> 'participant_id')::uuid), '고양이', '거절되면 참가 행 닉네임 그대로');
end $$;
reset role;
rollback;
