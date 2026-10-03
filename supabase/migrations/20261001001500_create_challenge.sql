-- 새 챌린지 만들기(콘솔 OP0, docs/02 D44). 1회차 1개 정책을 풀어 운영자가 여러 챌린지를 만든다.
-- 챌린지(초안)와 기본 규칙 행을 한 번에 만든다. 상태·운영자는 서버가 정하고, 초대코드는 지금처럼 모집 시작 때 발급한다.
-- 검사는 기능정의서 F-OP-01: 기간 7~30일, 정원 30~100명. 시작일은 오늘(KST) 이후.

create or replace function create_challenge(p jsonb) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_name text := btrim(coalesce(p ->> 'name', ''));
  v_start date;
  v_end date;
  v_cap int;
  ch challenges;
begin
  if v_uid is null then raise exception 'login required' using errcode = 'PT401'; end if;
  if not exists (select 1 from users where id = v_uid and is_operator) then
    raise exception '운영자만 챌린지를 만들 수 있어요' using errcode = 'PT403';
  end if;
  begin
    v_start := (p ->> 'start_date')::date;
    v_end := (p ->> 'end_date')::date;
    v_cap := (p ->> 'capacity')::int;
  exception when others then
    raise exception '기간과 정원을 다시 확인해 주세요' using errcode = 'PT422';
  end;
  if v_name = '' then raise exception '챌린지 이름을 입력해 주세요' using errcode = 'PT422'; end if;
  if v_start is null or v_end is null then raise exception '기간을 입력해 주세요' using errcode = 'PT422'; end if;
  if v_start < kst_date(now()) then raise exception '시작일은 오늘 이후로 정해 주세요' using errcode = 'PT422'; end if;
  if v_end - v_start + 1 not between 7 and 30 then raise exception '기간은 7~30일로 정해 주세요' using errcode = 'PT422'; end if;
  if v_cap is null or v_cap not between 30 and 100 then raise exception '정원은 30~100명으로 정해 주세요' using errcode = 'PT422'; end if;

  insert into challenges (name, start_date, end_date, capacity, operator_id)
  values (v_name, v_start, v_end, v_cap, v_uid)
  returning * into ch;
  insert into challenge_rules (challenge_id) values (ch.id);
  perform write_audit(ch.id, v_uid, 'operator', 'challenge_create',
    jsonb_build_object('name', v_name, 'start_date', v_start, 'end_date', v_end, 'capacity', v_cap));
  return jsonb_build_object('id', ch.id, 'status', ch.status);
end $$;

revoke execute on function create_challenge(jsonb) from public, anon;
grant execute on function create_challenge(jsonb) to authenticated, service_role;
