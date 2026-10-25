-- 참가자는 users 행을 직접 쓰지 못한다(운영자 권한 is_operator 를 스스로 켤 수 없게). 쓰기는 서버 함수(join_challenge·set_my_settings·delete_account 등)만.
begin;
select tests.login(tests.uid('지수'));
set local role authenticated;
do $$
begin
  perform tests.throws(format('update users set is_operator = true where id = %L', auth.uid()), '42501', '운영자 권한을 스스로 켤 수 없음');
  perform tests.throws(format('update users set nickname = %L where id = %L', '바꾼이름', auth.uid()), '42501', '닉네임도 직접 못 바꿈(서버 함수로만)');
  perform tests.throws(format('insert into users (id, nickname, is_operator) values (%L, %L, true)', gen_random_uuid(), 'x'), '42501', '행 직접 추가 불가');
  perform tests.ok(exists (select 1 from users where id = auth.uid()), '내 행 읽기는 그대로');
end $$;
reset role;
rollback;
