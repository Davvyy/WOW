-- 동의는 사용자·종류·버전당 유효(철회 전) 1건만 둔다.
-- join_challenge 는 다시 불려도(온보딩 반복·재시도) 같은 결과여야 하는데, 동의만 매번 새로 쌓이고 있었다.
-- 철회한 뒤 다시 동의하면 새 행이 생긴다(철회 행은 인덱스 밖).

-- 1) 이미 쌓인 중복: 가장 먼저 받은 동의만 남긴다
delete from consents c
using consents d
where c.user_id = d.user_id and c.type = d.type and c.version = d.version
  and c.revoked_at is null and d.revoked_at is null
  and (d.granted_at, d.id) < (c.granted_at, c.id);

-- 2) 유효 동의 중복 방지
create unique index consents_active_once on consents (user_id, type, version) where revoked_at is null;

-- 3) 참가: 동의 저장만 바뀜(on conflict do nothing). 나머지는 20261001000400_rls.sql 과 같다.
create or replace function join_challenge(p jsonb) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  ch challenges;
  v_age int; v_age_cons int; v_bmr int; v_bmi numeric;
  v_reason record_mode_reason;
  v_part participants;
  v_ver text := coalesce(p ->> 'consent_version', 'v1');
begin
  if v_uid is null then raise exception 'login required' using errcode = 'PT401'; end if;
  select * into ch from challenges where invite_code = upper(p ->> 'code') for update;
  if not found or ch.status <> 'recruiting' then raise exception '코드를 다시 확인해 주세요' using errcode = 'PT404'; end if;
  if not coalesce((p #>> '{consents,terms}')::boolean, false) or not coalesce((p #>> '{consents,sensitive_health}')::boolean, false) then
    raise exception '필수 동의가 필요해요' using errcode = 'PT422';
  end if;
  if exists (select 1 from participants where challenge_id = ch.id and user_id = v_uid and block_rejoin) then
    raise exception '참가할 수 없는 챌린지예요' using errcode = 'PT403';
  end if;
  if (select count(*) from participants where challenge_id = ch.id and status not in ('kicked', 'left')) >= ch.capacity then
    raise exception '정원이 찼어요' using errcode = 'PT409';
  end if;

  v_age := extract(year from ch.start_date)::int - (p ->> 'birth_year')::int;        -- BMR 나이
  v_age_cons := v_age - 1;                                                           -- 12/31생 보수 판정
  if v_age_cons < 14 then raise exception '만 14세 이상부터 참가할 수 있어요' using errcode = 'PT422'; end if;
  v_bmi := (p ->> 'weight_kg')::numeric / power((p ->> 'height_cm')::numeric / 100, 2);
  v_reason := case
    when v_age_cons < 19 then 'minor'
    when v_bmi < 18.5 then 'bmi'
    when coalesce((p ->> 'pregnancy')::boolean, false) then 'pregnancy'
    when coalesce((p ->> 'eating_disorder')::boolean, false) then 'eating_disorder' end;
  v_bmr := bmr_kcal((p ->> 'sex')::sex_type, (p ->> 'weight_kg')::numeric, (p ->> 'height_cm')::numeric, v_age);

  insert into users (id, nickname) values (v_uid, p ->> 'nickname')
  on conflict (id) do update set nickname = excluded.nickname;
  insert into profiles (user_id, sex, birth_year, height_cm, weight_kg, bmr_age, record_mode, record_mode_reason)
  values (v_uid, (p ->> 'sex')::sex_type, (p ->> 'birth_year')::int, (p ->> 'height_cm')::numeric, (p ->> 'weight_kg')::numeric,
    v_age, v_reason is not null, v_reason)
  on conflict (user_id) do update set sex = excluded.sex, birth_year = excluded.birth_year, height_cm = excluded.height_cm,
    weight_kg = excluded.weight_kg, bmr_age = excluded.bmr_age, record_mode = excluded.record_mode, record_mode_reason = excluded.record_mode_reason;
  insert into consents (user_id, type, version)
  select v_uid, t::consent_type, v_ver from unnest(array['terms', 'sensitive_health']) t
  union all select v_uid, 'overseas_ai', v_ver where coalesce((p #>> '{consents,overseas_ai}')::boolean, false)
  on conflict (user_id, type, version) where revoked_at is null do nothing;

  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, status, rank_eligible)
  values (ch.id, v_uid, p ->> 'nickname', (p ->> 'sex')::sex_type, (p ->> 'birth_year')::int, v_age, (p ->> 'height_cm')::numeric,
    (p ->> 'weight_kg')::numeric, v_bmr, (case when v_reason is null then 'active' else 'record_mode' end)::participant_status, v_reason is null)
  on conflict (challenge_id, user_id) do update set nickname = excluded.nickname
  returning * into v_part;

  return jsonb_build_object('participant_id', v_part.id, 'challenge_id', ch.id, 'bmr', v_bmr,
    'm_p', m_p(v_bmr, engine_rules(ch.id)), 'f_p', f_p(v_bmr, engine_rules(ch.id)), 'record_mode', v_reason is not null);
end $$;
