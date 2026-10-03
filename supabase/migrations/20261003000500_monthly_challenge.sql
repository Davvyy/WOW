-- 월간 자동 챌린지(docs/02 D46)·다음 달 자동 참가(D51)
create table app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
alter table app_settings enable row level security; -- 정책 없음: service_role·security definer 함수만
revoke all on app_settings from anon, authenticated;
-- 월간 챌린지의 운영자: 가장 먼저 만든 운영자 계정(운영 DB 에는 하나)
insert into app_settings (key, value)
select 'monthly_operator_id', to_jsonb(id) from users where is_operator order by created_at limit 1
on conflict (key) do nothing;

-- 그 달(KST) 월간 챌린지를 돌려준다. 없으면 1일~말일·진행 중·규칙 잠금으로 만들고, 지난달 월간을 유지한 사람 중
-- 자동 이어하기를 켠 사람을 최신 프로필로 BMR 을 다시 잠가 참가시킨다(동시 3개 제한 안에서).
create or replace function ensure_monthly_challenge(p_now timestamptz default now()) returns uuid
  language plpgsql as $$
declare
  v_start date := date_trunc('month', kst_date(p_now))::date;
  v_end date := (date_trunc('month', kst_date(p_now)) + interval '1 month - 1 day')::date;
  v_op uuid := (select (value #>> '{}')::uuid from app_settings where key = 'monthly_operator_id');
  v_id uuid; v_prev uuid; x record; v_age int; v_n int;
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
        and c.status in ('recruiting', 'checking', 'running', 'closing') and c.id not in (v_id, v_prev);
    continue when v_n >= 3;
    v_age := extract(year from v_start)::int - x.birth_year;
    insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked,
      status, rank_eligible, joined_at, check_start)
    values (v_id, x.user_id, x.nickname, x.sex, x.birth_year, v_age, x.height_cm, x.weight_kg,
      bmr_kcal(x.sex, x.weight_kg, x.height_cm, v_age),
      (case when x.record_mode then 'record_mode' else 'active' end)::participant_status, not x.record_mode, p_now, v_start)
    on conflict (challenge_id, user_id) do nothing;
  end loop;
  return v_id;
end $$;
revoke execute on function ensure_monthly_challenge(timestamptz) from public, anon, authenticated;
grant execute on function ensure_monthly_challenge(timestamptz) to service_role;

-- 00:00 KST 생명주기 배치: 그 달 월간 챌린지 먼저, 이어서 Recruiting→Checking(시작일)·Checking→Running(3일)·Published→Archived(7일)
create or replace function run_lifecycle(p_now timestamptz default now()) returns int
  language plpgsql as $$
declare ch challenges; v_today date := kst_date(p_now); n int := 0; r challenge_rules;
begin
  perform ensure_monthly_challenge(p_now);
  for ch in select * from challenges where status in ('recruiting', 'checking', 'published')
  loop
    r := engine_rules(ch.id);
    if ch.status = 'recruiting' and v_today >= ch.start_date then
      perform transition_challenge(ch.id, 'checking', null, p_now); n := n + 1;
    elsif ch.status = 'checking' and v_today >= ch.start_date + r.check_days then
      perform transition_challenge(ch.id, 'running', null, p_now); n := n + 1;
    elsif ch.status = 'published' and p_now >= ch.published_at + interval '7 days' then
      perform transition_challenge(ch.id, 'archived', null, p_now); n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- 운영 DB 에 초안으로 만들어 둔 '10월 챌린지'(2026-10-01~31)를 월간·진행 중으로 연다(로컬 테스트 DB 에는 없음)
update challenges set kind = 'monthly', status = 'running', capacity = null
where name = '10월 챌린지' and status = 'draft' and start_date = '2026-10-01' and end_date = '2026-10-31';
update challenge_rules set locked_at = now()
where locked_at is null and challenge_id in (select id from challenges where kind = 'monthly');
