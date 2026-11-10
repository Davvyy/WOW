-- 월간 자동 이어가기(D46)로 다음 달 챌린지에 넘어갈 때도 닉네임 중복 규칙(D81)을 지킨다.
-- 전에는 지난달 닉네임을 그대로 복사해, 중복 규칙이 생기기 전부터 겹쳐 있던 닉네임이 새 챌린지에도 겹친 채 들어갔다.
-- 겹치면 뒤에 번호(2, 3, …)를 붙인다. 본인은 설정에서 다시 바꿀 수 있다.
-- 본문은 20261003001000_fanout_followups.sql 그대로, 닉네임 정하는 줄만 더함.

create or replace function ensure_monthly_challenge(p_now timestamptz default now()) returns uuid
  language plpgsql as $$
declare
  v_start date := date_trunc('month', kst_date(p_now))::date;
  v_end date := (date_trunc('month', kst_date(p_now)) + interval '1 month - 1 day')::date;
  v_op uuid := (select (value #>> '{}')::uuid from app_settings where key = 'monthly_operator_id');
  v_id uuid; v_prev uuid; x record; v_age int; v_n int; v_nick text; v_i int;
begin
  select id into v_id from challenges where kind = 'monthly' and start_date = v_start;
  if v_id is not null then return v_id; end if;
  if v_op is null then
    raise notice 'monthly_operator_id not set — monthly challenge skipped';
    return null;
  end if;
  insert into challenges (name, kind, status, start_date, end_date, capacity, operator_id)
  values (format('%s월 챌린지', extract(month from v_start)::int), 'monthly', 'running', v_start, v_end, null, v_op)
  returning id into v_id;
  insert into challenge_rules (challenge_id, locked_at) values (v_id, p_now);
  perform write_audit(v_id, null, 'system', 'monthly_create', jsonb_build_object('start_date', v_start, 'end_date', v_end));

  select id into v_prev from challenges where kind = 'monthly' and start_date = (v_start - interval '1 month')::date;
  if v_prev is null then return v_id; end if;
  for x in
    select pt.user_id, pt.nickname, pr.sex, pr.birth_year, pr.height_cm, pr.weight_kg, pr.record_mode
    from participants pt
    join profiles pr on pr.user_id = pt.user_id
    join users u on u.id = pt.user_id
    where pt.challenge_id = v_prev and pt.status in ('active', 'record_mode') and pr.auto_continue and u.status = 'active'
  loop
    select count(*) into v_n from participants q join challenges c on c.id = q.challenge_id
      where q.user_id = x.user_id and q.status in ('active', 'record_mode', 'excluded')
        and c.status in ('recruiting', 'checking', 'running') and c.id not in (v_id, v_prev);
    continue when v_n >= 3;
    v_age := extract(year from v_start)::int - x.birth_year;
    -- 닉네임이 새 챌린지에서 이미 쓰이면 뒤에 번호를 붙인다(12자 안에서). 중복 규칙(D81) 전부터 겹쳐 있던 닉네임이 그대로 넘어오지 않게.
    v_nick := x.nickname; v_i := 2;
    while nickname_taken(v_id, btrim(v_nick), x.user_id) loop
      v_nick := left(x.nickname, 12 - length(v_i::text)) || v_i::text; v_i := v_i + 1;
    end loop;
    insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked,
      status, rank_eligible, joined_at, check_start)
    values (v_id, x.user_id, v_nick, x.sex, x.birth_year, v_age, x.height_cm, x.weight_kg,
      bmr_kcal(x.sex, x.weight_kg, x.height_cm, v_age),
      (case when x.record_mode then 'record_mode' else 'active' end)::participant_status, not x.record_mode, p_now, v_start)
    on conflict (challenge_id, user_id) do nothing;
  end loop;
  return v_id;
end $$;
