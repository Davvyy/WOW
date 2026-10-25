-- 보안: 참가자가 users 행을 직접 쓰지 못하게 한다. 지금까지 authenticated 에 insert·update 가 열려 있어
-- 자기 행의 is_operator(운영자 권한)를 스스로 켤 수 있었다. 앱은 users 를 직접 쓰지 않고
-- 서버 함수(join_challenge·set_my_settings·delete_account 등, security definer)로만 쓰므로 읽기만 남긴다.
revoke insert, update, delete on users from authenticated, anon;
