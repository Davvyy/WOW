-- 테스트 헬퍼(단언). pgTAP 없이 순수 SQL로 동작한다.
create schema if not exists tests;
create or replace function tests.eq(p_actual anyelement, p_expected anyelement, p_label text) returns void
  language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected % got %', p_label, p_expected, p_actual;
  end if;
  raise notice 'ok - %', p_label;
end $$;
create or replace function tests.ok(p_cond boolean, p_label text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL %', p_label; end if;
  raise notice 'ok - %', p_label;
end $$;
-- p_sql 실행이 오류(선택: SQLSTATE·메시지 일부)로 끝나야 통과
create or replace function tests.throws(p_sql text, p_state text, p_label text, p_msg_like text default null) returns void
  language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_state is not null and sqlstate <> p_state then
      raise exception 'FAIL %: expected SQLSTATE % got % (%)', p_label, p_state, sqlstate, sqlerrm;
    end if;
    if p_msg_like is not null and sqlerrm not like p_msg_like then
      raise exception 'FAIL %: message % not like %', p_label, sqlerrm, p_msg_like;
    end if;
    raise notice 'ok - % (% %)', p_label, sqlstate, sqlerrm;
    return;
  end;
  raise exception 'FAIL %: no error', p_label;
end $$;
create or replace function tests.pid(p_nick text) returns uuid language sql stable security definer set search_path = public as $$
  select id from participants where nickname = p_nick
$$;
create or replace function tests.uid(p_nick text) returns uuid language sql stable security definer set search_path = public as $$
  select user_id from participants where nickname = p_nick
$$;
-- RLS 테스트용: 해당 사용자로 전환
create or replace function tests.login(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
end $$;
-- 시험용 참가자 1명(새 사용자·users 행 포함). 신체값은 고정(여 1990년생 160 cm 55 kg).
create or replace function tests.new_participant(p_challenge uuid, p_nick text, p_joined timestamptz) returns uuid
  language plpgsql security definer set search_path = public as $$
declare u uuid := gen_random_uuid(); v uuid;
begin
  insert into auth.users (id) values (u);
  insert into users (id, provider, nickname) values (u, 'kakao', p_nick);
  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, joined_at)
  values (p_challenge, u, p_nick, 'F', 1990, 36, 160, 55, bmr_kcal('F', 55, 160, 36), p_joined)
  returning id into v;
  return v;
end $$;
grant usage on schema tests to authenticated, anon;
grant execute on all functions in schema tests to authenticated, anon;
