-- 없는 토큰 정리: 발송 함수가 FCM 에서 404 UNREGISTERED(앱 삭제·재설치로 사라진 토큰)를 받으면 그 기기 행을 지운다.
-- 앱이 같은 기기 id 로 다시 등록하면 register_device 가 새 행을 만든다. 지운 행 수를 돌려준다.
create or replace function forget_push_tokens(p_tokens text[]) returns int
  language sql security definer set search_path = public as $$
  with d as (delete from devices where push_token = any(p_tokens) returning 1)
  select count(*)::int from d
$$;
revoke execute on function forget_push_tokens(text[]) from public, anon, authenticated;
grant execute on function forget_push_tokens(text[]) to service_role;
