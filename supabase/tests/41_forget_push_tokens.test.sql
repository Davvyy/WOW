-- 없는 토큰 정리(forget_push_tokens): FCM 이 UNREGISTERED 로 답한 토큰의 기기 행을 지운다. 발송 함수(service_role)만 부른다.
begin;
do $$
declare jisu uuid := tests.uid('지수'); n int;
begin
  delete from devices where user_id = jisu;
  insert into devices (user_id, platform, push_token, push_permission) values
    (jisu, 'android', 'dead-token-1', 'granted'), (jisu, 'android', 'live-token', 'granted');
  n := forget_push_tokens(array['dead-token-1', 'never-existed']);
  perform tests.eq(n, 1, '지운 행 수');
  perform tests.ok(not exists (select 1 from devices where push_token = 'dead-token-1'), '없는 토큰 행 삭제');
  perform tests.ok(exists (select 1 from devices where push_token = 'live-token'), '다른 토큰은 그대로');
  perform tests.eq(forget_push_tokens(array[]::text[]), 0, '빈 목록은 0');
  perform tests.ok(not has_function_privilege('authenticated', 'forget_push_tokens(text[])', 'execute'), '앱 사용자는 못 부름');
  perform tests.ok(has_function_privilege('service_role', 'forget_push_tokens(text[])', 'execute'), '발송 함수는 부름');
end $$;
rollback;
