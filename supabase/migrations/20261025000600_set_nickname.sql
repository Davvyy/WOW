-- 닉네임 바꾸기(설정, docs/02 D81). 지금까지 닉네임은 참가할 때만 정했고 서버 확인이 없었다.
-- 규칙: 앞뒤 공백을 지운 2~12자(글자 수). 내가 지금 있는 챌린지마다 다른 참가자(강퇴·나감 제외)와 대소문자 무시로 겹치면 안 된다.
-- set_my_nickname 은 users 와 진행 중(모집·점검·진행·마감) 챌린지의 내 참가 행을 같이 바꾼다. 신고·판정은 참가 행 id 로 묶여 있어 그대로다.
-- 순위 스냅샷은 매시 다시 만들어지므로 지난 스냅샷은 고치지 않는다(다음 스냅샷부터 새 닉네임).
-- join_challenge 도 같은 길이 규칙과, 참가하려는 챌린지 안의 중복 규칙을 지킨다(본문은 20261003001000 그대로, 닉네임 확인만 더함).
-- 참가 행 닉네임 직접 쓰기(컬럼 권한)는 닫는다: 앱은 쓰지 않았고, 열어 두면 중복 규칙을 건너뛸 수 있다.

-- 앞뒤 공백을 지운 닉네임. 2~12자가 아니면 422.
create or replace function nickname_normalize(p text) returns text
  language plpgsql immutable as $$
declare v text := btrim(coalesce(p, ''), E' \t\r\n　');
begin
  if char_length(v) not between 2 and 12 then
    raise exception '닉네임은 2~12자로 정해 주세요' using errcode = 'PT422';
  end if;
  return v;
end $$;

-- 이 챌린지에 [p_user] 가 아닌 참가자(강퇴·나감 제외)가 같은 닉네임(대소문자·앞뒤 공백 무시)을 쓰는지
create or replace function nickname_taken(p_challenge uuid, p_nick text, p_user uuid) returns boolean
  language sql stable as $$
  select exists (select 1 from participants q
    where q.challenge_id = p_challenge and q.user_id is distinct from p_user and q.status not in ('kicked', 'left')
      and lower(btrim(q.nickname, E' \t\r\n　')) = lower(p_nick))
$$;

create or replace function set_my_nickname(p_nickname text) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_nick text;
  x record;
begin
  if v_uid is null then raise exception '로그인이 필요해요' using errcode = 'PT401'; end if;
  v_nick := nickname_normalize(p_nickname);
  -- 내가 있는 진행 중 챌린지를 id 순으로 잠근다: join_challenge 의 챌린지 잠금(for update)과 겹쳐 동시에 같은 닉네임이 들어오지 않게
  for x in select c.id, q.nickname as mine from challenges c join participants q on q.challenge_id = c.id
      where q.user_id = v_uid and q.status not in ('kicked', 'left') and c.status in ('recruiting', 'checking', 'running', 'closing')
      order by c.id for no key update of c loop
    -- 지금 내 닉네임(대소문자만 다른 것 포함)은 그 챌린지에서 이미 내 것이라 다시 확인하지 않는다
    if lower(btrim(x.mine, E' \t\r\n　')) <> lower(v_nick) and nickname_taken(x.id, v_nick, v_uid) then
      raise exception '이미 같은 챌린지에 있는 닉네임이에요' using errcode = 'PT409';
    end if;
  end loop;

  insert into users (id, nickname) values (v_uid, v_nick)
  on conflict (id) do update set nickname = excluded.nickname;
  update participants q set nickname = v_nick
  from challenges c
  where c.id = q.challenge_id and q.user_id = v_uid and q.status not in ('kicked', 'left')
    and c.status in ('recruiting', 'checking', 'running', 'closing') and q.nickname is distinct from v_nick;
  return jsonb_build_object('nickname', v_nick);
end $$;

-- ---------------------------------------------------------------- 참가(05 API #3)
-- 원본(20261003001000_fanout_followups.sql)에서 바꾼 것: 닉네임 길이(2~12자) · 이 챌린지 안의 중복 확인, 앞뒤 공백을 지워 저장.
--   다시 참가(이미 참가 중): 닉네임을 보냈을 때만 확인한다. 지금 내 닉네임 그대로(대소문자만 다른 것 포함)면 중복 확인 없이 통과(재시도 멱등).
--   새 참가: 3개 제한까지 확인한 뒤 확인한다. 챌린지 행을 잠근 채라 같은 닉네임 동시 참가는 하나만 들어온다.
create or replace function join_challenge(p jsonb) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  ch challenges;
  v_age int; v_age_cons int; v_bmr int; v_bmi numeric;
  v_reason record_mode_reason;
  v_part participants;
  v_ver text := coalesce(p ->> 'consent_version', 'v1');
  v_active int;
  v_nick text;
begin
  if v_uid is null then raise exception 'login required' using errcode = 'PT401'; end if;
  if p ? 'challenge_id' then
    select * into ch from challenges where id = (p ->> 'challenge_id')::uuid and kind = 'monthly' for update;
  else
    select * into ch from challenges where invite_code = upper(p ->> 'code') for update;
  end if;
  if not found or ch.status not in ('recruiting', 'checking', 'running') then
    raise exception '코드를 다시 확인해 주세요' using errcode = 'PT404';
  end if;
  -- 이미 이 챌린지에 참가 중이면 다시 참가(닉네임 갱신): 마감·남은 기간·동의·정원·3개 제한보다 먼저(재시도 멱등)
  select * into v_part from participants where challenge_id = ch.id and user_id = v_uid and status in ('active', 'record_mode', 'excluded');
  if found then
    if p ->> 'nickname' is not null then
      v_nick := nickname_normalize(p ->> 'nickname');
      if lower(btrim(v_part.nickname, E' \t\r\n　')) <> lower(v_nick) and nickname_taken(ch.id, v_nick, v_uid) then
        raise exception '이미 같은 챌린지에 있는 닉네임이에요' using errcode = 'PT409';
      end if;
    end if;
    update participants set nickname = coalesce(v_nick, nickname) where id = v_part.id returning * into v_part;
    return jsonb_build_object('participant_id', v_part.id, 'challenge_id', ch.id, 'kind', ch.kind, 'check_start', v_part.check_start,
      'bmr', v_part.bmr_locked, 'm_p', m_p(v_part.bmr_locked, engine_rules(ch.id)), 'f_p', f_p(v_part.bmr_locked, engine_rules(ch.id)),
      'record_mode', v_part.status = 'record_mode');
  end if;
  if not ch.join_open then raise exception '참가가 마감된 챌린지예요' using errcode = 'PT403'; end if;
  if not join_feasible(ch, kst_date(now())) then
    raise exception '남은 기간이 짧아 이번 챌린지에는 참가할 수 없어요. 다음 챌린지에서 만나요' using errcode = 'PT422';
  end if;
  if not coalesce((p #>> '{consents,terms}')::boolean, false) or not coalesce((p #>> '{consents,sensitive_health}')::boolean, false) then
    raise exception '필수 동의가 필요해요' using errcode = 'PT422';
  end if;
  if exists (select 1 from participants where challenge_id = ch.id and user_id = v_uid and block_rejoin) then
    raise exception '참가할 수 없는 챌린지예요' using errcode = 'PT403';
  end if;
  if ch.capacity is not null
     and (select count(*) from participants where challenge_id = ch.id and status not in ('kicked', 'left')) >= ch.capacity then
    raise exception '정원이 찼어요' using errcode = 'PT409';
  end if;
  -- 동시 참가 최대 3개(D47). 이미 이 챌린지에 참가 중이면 다시 참가(닉네임 갱신)로 본다.
  perform pg_advisory_xact_lock(hashtext(v_uid::text)); -- 같은 사용자의 동시 참가 요청이 함께 3개 제한을 넘지 않게
  if not exists (select 1 from participants where challenge_id = ch.id and user_id = v_uid and status in ('active', 'record_mode', 'excluded')) then
    select count(*) into v_active from participants q join challenges c on c.id = q.challenge_id
      where q.user_id = v_uid and q.status in ('active', 'record_mode', 'excluded')
        and c.status in ('recruiting', 'checking', 'running');
    if v_active >= 3 then raise exception '동시에 3개까지 참가할 수 있어요' using errcode = 'PT409'; end if;
  end if;
  -- 닉네임(D81): 2~12자 · 이 챌린지의 다른 참가자와 겹치지 않게(대소문자 무시)
  v_nick := nickname_normalize(p ->> 'nickname');
  if nickname_taken(ch.id, v_nick, v_uid) then
    raise exception '이미 같은 챌린지에 있는 닉네임이에요' using errcode = 'PT409';
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

  insert into users (id, nickname) values (v_uid, v_nick)
  on conflict (id) do update set nickname = excluded.nickname;
  insert into profiles (user_id, sex, birth_year, height_cm, weight_kg, bmr_age, record_mode, record_mode_reason, auto_continue)
  values (v_uid, (p ->> 'sex')::sex_type, (p ->> 'birth_year')::int, (p ->> 'height_cm')::numeric, (p ->> 'weight_kg')::numeric,
    v_age, v_reason is not null, v_reason, coalesce((p ->> 'auto_continue')::boolean, true))
  on conflict (user_id) do update set sex = excluded.sex, birth_year = excluded.birth_year, height_cm = excluded.height_cm,
    weight_kg = excluded.weight_kg, bmr_age = excluded.bmr_age, record_mode = excluded.record_mode, record_mode_reason = excluded.record_mode_reason,
    auto_continue = coalesce((p ->> 'auto_continue')::boolean, profiles.auto_continue);
  insert into consents (user_id, type, version)
  select v_uid, t::consent_type, v_ver from unnest(array['terms', 'sensitive_health']) t
  union all select v_uid, 'overseas_ai', v_ver where coalesce((p #>> '{consents,overseas_ai}')::boolean, false)
  on conflict (user_id, type, version) where revoked_at is null do nothing;

  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, status, rank_eligible)
  values (ch.id, v_uid, v_nick, (p ->> 'sex')::sex_type, (p ->> 'birth_year')::int, v_age, (p ->> 'height_cm')::numeric,
    (p ->> 'weight_kg')::numeric, v_bmr, (case when v_reason is null then 'active' else 'record_mode' end)::participant_status, v_reason is null)
  on conflict (challenge_id, user_id) do update set nickname = excluded.nickname
  returning * into v_part;

  return jsonb_build_object('participant_id', v_part.id, 'challenge_id', ch.id, 'kind', ch.kind, 'check_start', v_part.check_start,
    'bmr', v_bmr, 'm_p', m_p(v_bmr, engine_rules(ch.id)), 'f_p', f_p(v_bmr, engine_rules(ch.id)), 'record_mode', v_reason is not null);
end $$;

-- 권한: set_my_nickname 은 로그인 사용자만. 확인 함수는 서버 함수 안에서만 쓴다.
revoke execute on function set_my_nickname(text) from public, anon;
grant execute on function set_my_nickname(text) to authenticated;
revoke execute on function nickname_normalize(text), nickname_taken(uuid, text, uuid) from public, anon, authenticated;
-- 참가 행 닉네임은 set_my_nickname · join_challenge 로만 바꾼다(중복 규칙). 순위 공개·배지 컬럼 권한은 그대로.
revoke update (nickname) on participants from authenticated;
