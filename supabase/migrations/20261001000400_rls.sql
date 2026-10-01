-- RLS·권한 (docs/05 §3·§8): 참가자는 자기 행만, 운영자는 operator_id 챌린지만.
-- 리더보드는 스냅샷으로만(타인 원본 조회 불가). 쓰기 대부분은 Edge Function(service_role)이 SQL 함수로 수행.

-- ---------------------------------------------------------------- 헬퍼(security definer: RLS 재귀 방지)
create or replace function is_challenge_operator(p_challenge uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from challenges where id = p_challenge and operator_id = auth.uid())
$$;

create or replace function is_challenge_member(p_challenge uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from participants where challenge_id = p_challenge and user_id = auth.uid() and status not in ('kicked', 'left'))
$$;

create or replace function owns_participant(p_participant uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from participants where id = p_participant and user_id = auth.uid())
$$;

create or replace function operates_participant(p_participant uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from participants p join challenges c on c.id = p.challenge_id
    where p.id = p_participant and c.operator_id = auth.uid())
$$;

-- ---------------------------------------------------------------- 권한 기본값
revoke all on all tables in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;
revoke select on sync_batches, idempotency_keys from authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

-- 클라이언트 직접 쓰기(05 §4 R: 쓰기 #4·#5·#18·#23·#26·#32 등)
grant insert, update on users, profiles, consents, devices to authenticated;
grant insert on challenges to authenticated;
grant update (name, start_date, end_date, capacity, rules_md) on challenges to authenticated;
grant insert, update on challenge_rules to authenticated;
grant update (nickname, leaderboard_visible, grade_badge_public, status, block_rejoin) on participants to authenticated;
grant insert, update on participant_notes to authenticated;
grant insert on weights, cheers, appeals to authenticated;
grant update (read_at) on notifications to authenticated;
grant delete on devices to authenticated;

-- RLS 활성화
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- 계정
create policy users_self on users for all to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_self on profiles for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy consents_self on consents for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy devices_self on devices for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 프로필 잠금: 잠금된(Checking 이후) 챌린지에 참가 중이면 4항목 변경 거부(04 §2, 운영자 정정은 service_role)
create or replace function profiles_lock_guard() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon')
     and (new.sex, new.birth_year, new.height_cm, new.weight_kg, new.bmr_age) is distinct from (old.sex, old.birth_year, old.height_cm, old.weight_kg, old.bmr_age)
     and exists (select 1 from participants p join challenge_rules r on r.challenge_id = p.challenge_id
       where p.user_id = old.user_id and r.locked_at is not null and p.status not in ('left', 'kicked')) then
    raise exception '챌린지가 시작되어 프로필이 잠겼어요' using errcode = 'PT422';
  end if;
  return new;
end $$;
create trigger profiles_lock before update on profiles for each row execute function profiles_lock_guard();

-- ---------------------------------------------------------------- 챌린지
create policy challenges_read on challenges for select to authenticated
  using (operator_id = auth.uid() or is_challenge_member(id));
create policy challenges_insert on challenges for insert to authenticated
  with check (operator_id = auth.uid() and exists (select 1 from users u where u.id = auth.uid() and u.is_operator));
create policy challenges_update on challenges for update to authenticated
  using (operator_id = auth.uid()) with check (operator_id = auth.uid());

-- 기간·정원은 시작 전(draft/recruiting)만
create or replace function challenges_edit_guard() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') and old.status not in ('draft', 'recruiting')
     and (new.start_date, new.end_date, new.capacity) is distinct from (old.start_date, old.end_date, old.capacity) then
    raise exception '시작 뒤에는 기간·정원을 바꿀 수 없어요' using errcode = 'PT422';
  end if;
  return new;
end $$;
create trigger challenges_edit before update on challenges for each row execute function challenges_edit_guard();

create policy rules_read on challenge_rules for select to authenticated
  using (is_challenge_operator(challenge_id) or is_challenge_member(challenge_id));
create policy rules_write on challenge_rules for insert to authenticated with check (is_challenge_operator(challenge_id));
create policy rules_update on challenge_rules for update to authenticated
  using (is_challenge_operator(challenge_id) and locked_at is null)
  with check (is_challenge_operator(challenge_id) and locked_at is null);

create policy teams_read on teams for select to authenticated
  using (is_challenge_operator(challenge_id) or is_challenge_member(challenge_id));

-- ---------------------------------------------------------------- 참가자
create policy participants_read on participants for select to authenticated
  using (user_id = auth.uid() or is_challenge_operator(challenge_id));
create policy participants_update on participants for update to authenticated
  using (user_id = auth.uid() or is_challenge_operator(challenge_id))
  with check (user_id = auth.uid() or is_challenge_operator(challenge_id));

-- 본인은 표시 설정만, 운영자는 상태·재가입 차단만(컬럼 권한과 함께)
create or replace function participants_update_guard() returns trigger language plpgsql as $$
declare v_op boolean;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  v_op := is_challenge_operator(old.challenge_id);
  if not v_op and (new.status, new.block_rejoin) is distinct from (old.status, old.block_rejoin) then
    raise exception 'operator only' using errcode = 'PT403';
  end if;
  if v_op and old.user_id is distinct from auth.uid()
     and (new.nickname, new.leaderboard_visible, new.grade_badge_public) is distinct from (old.nickname, old.leaderboard_visible, old.grade_badge_public) then
    raise exception 'participant only' using errcode = 'PT403';
  end if;
  if v_op and new.status is distinct from old.status then
    if new.status not in ('active', 'excluded', 'kicked') then raise exception 'invalid status' using errcode = 'PT422'; end if;
    new.rank_eligible := new.status = 'active' and old.warning_count < 3;
  end if;
  return new;
end $$;
create trigger participants_update before update on participants for each row execute function participants_update_guard();

-- 상태·재가입 차단 변경 감사 로그(트리거 함수는 RPC로 직접 호출할 수 없음)
create or replace function participants_audit() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if (new.status, new.block_rejoin) is distinct from (old.status, old.block_rejoin) then
    insert into audit_logs (challenge_id, actor_id, actor_role, action, target, before, after)
    values (old.challenge_id, auth.uid(), case when auth.uid() is null then 'system' else 'operator' end, 'participant_status',
      jsonb_build_object('participant_id', old.id),
      jsonb_build_object('status', old.status, 'block_rejoin', old.block_rejoin),
      jsonb_build_object('status', new.status, 'block_rejoin', new.block_rejoin));
  end if;
  return null;
end $$;
create trigger participants_audit after update on participants for each row execute function participants_audit();

create policy notes_operator on participant_notes for all to authenticated
  using (is_challenge_operator(challenge_id)) with check (is_challenge_operator(challenge_id));

-- ---------------------------------------------------------------- 참가자 범위 데이터: 본인 또는 운영자 읽기
create policy daily_activity_read on daily_activity for select to authenticated
  using (owns_participant(participant_id) or is_challenge_operator(challenge_id));
create policy activity_sessions_read on activity_sessions for select to authenticated
  using (owns_participant(participant_id) or is_challenge_operator(challenge_id));
create policy photos_read on photos for select to authenticated
  using (owns_participant(participant_id) or is_challenge_operator(challenge_id));
create policy meals_read on meals for select to authenticated
  using (owns_participant(participant_id) or is_challenge_operator(challenge_id));
create policy meal_items_read on meal_items for select to authenticated
  using (exists (select 1 from meals m where m.id = meal_id));  -- meals RLS 를 그대로 따름
create policy daily_scores_read on daily_scores for select to authenticated
  using (owns_participant(participant_id) or is_challenge_operator(challenge_id));
create policy score_revisions_read on score_revisions for select to authenticated
  using (owns_participant(participant_id) or operates_participant(participant_id));
create policy weights_read on weights for select to authenticated
  using (owns_participant(participant_id) or is_challenge_operator(challenge_id));
create policy weights_insert on weights for insert to authenticated
  with check (owns_participant(participant_id)
    and challenge_id = (select challenge_id from participants where id = participant_id));

-- 음식 DB: 로그인 사용자 읽기
create policy food_read on food_db_cache for select to authenticated using (true);
create policy synonyms_read on food_synonyms for select to authenticated using (true);

-- ---------------------------------------------------------------- 리더보드·응원
create policy snapshots_read on leaderboard_snapshots for select to authenticated
  using (is_challenge_member(challenge_id) or is_challenge_operator(challenge_id));

create policy cheers_read on cheers for select to authenticated
  using (is_challenge_member(challenge_id) or is_challenge_operator(challenge_id));
create policy cheers_insert on cheers for insert to authenticated
  with check (owns_participant(from_participant_id)
    and challenge_id = (select challenge_id from participants where id = from_participant_id)
    and exists (select 1 from participants t where t.id = to_participant_id and t.challenge_id = cheers.challenge_id)
    and local_date = kst_date());

-- ---------------------------------------------------------------- 검토·소명·건강 알림
create policy reviews_read on reviews for select to authenticated
  using (owns_participant(participant_id) or is_challenge_operator(challenge_id));
create policy reporters_operator on review_reporters for select to authenticated
  using (exists (select 1 from reviews r where r.id = review_id and is_challenge_operator(r.challenge_id)));

create policy appeals_read on appeals for select to authenticated
  using (owns_participant(participant_id) or operates_participant(participant_id));
-- 소명 1회(UNIQUE review_id), 72h 이내, 열린 검토만
create policy appeals_insert on appeals for insert to authenticated
  with check (owns_participant(participant_id) and exists (
    select 1 from reviews r where r.id = review_id and r.participant_id = appeals.participant_id
      and r.status = 'open' and r.type not in ('report') and now() <= coalesce(r.sla_due_at, r.created_at + interval '72 hours')));

create or replace function appeals_after_insert() returns trigger language plpgsql security definer set search_path = public as $$
begin
  update reviews set status = 'appealed' where id = new.review_id and status = 'open';
  return new;
end $$;
create trigger appeals_mark after insert on appeals for each row execute function appeals_after_insert();

-- 건강 알림: OP2 비공개 섹션 전용(운영자만, 당사자·타인 불가)
create policy health_alerts_operator on health_alerts for select to authenticated
  using (is_challenge_operator(challenge_id));

create policy notifications_self on notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_read_mark on notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy audit_operator on audit_logs for select to authenticated using (is_challenge_operator(challenge_id));

-- ---------------------------------------------------------------- 뷰(security_invoker: 호출자 RLS 적용)
create or replace view v_challenge_summary with (security_invoker = true) as
select c.id, c.name, c.status, c.start_date, c.end_date, c.capacity, c.invite_code,
  (select count(*) from participants p where p.challenge_id = c.id and p.status not in ('kicked', 'left')) as joined,
  challenge_open_review_count(c.id) as open_reviews,
  (select count(*) filter (where p.last_synced_at >= kst_at(kst_date(), '00:00'))::numeric / nullif(count(*), 0)
     from participants p where p.challenge_id = c.id and p.status not in ('kicked', 'left')) as sync_rate_today,
  (select count(*) from meals m where m.challenge_id = c.id and m.local_date = kst_date() and m.status in ('captured', 'draft', 'failed')) as unconfirmed_meals_today,
  kst_date() - c.start_date + 1 as day_index
from challenges c;

create or replace view v_participant_sync with (security_invoker = true) as
select p.id, p.challenge_id, p.nickname, p.status, p.rank_eligible, p.warning_count, p.block_rejoin, p.last_synced_at, p.last_sync_source,
  (select count(*) from reviews r where r.participant_id = p.id and r.status in ('open', 'appealed')) as open_reviews,
  (select coalesce(sum(s.s_d), 0) from daily_scores s where s.participant_id = p.id and s.is_counted and s.is_final) as cumulative,
  (select a.steps_total from daily_activity a where a.participant_id = p.id and a.local_date = kst_date()) as steps_today,
  (select count(*) from meals m where m.participant_id = p.id and m.local_date = kst_date()
     and m.status in ('confirmed', 'auto', 'corrected') and m.slot <> 'snack') as meals_today,
  coalesce(p.last_synced_at < now() - interval '24 hours', true) as unsynced
from participants p;

grant select on v_challenge_summary, v_participant_sync to authenticated;

-- ---------------------------------------------------------------- 공개 RPC
-- 초대코드 조회(05 API #2): 로그인 전에도 챌린지 요약만
create or replace function get_invite(p_code text) returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object('challenge_id', c.id, 'name', c.name, 'status', c.status, 'start_date', c.start_date,
    'end_date', c.end_date, 'capacity', c.capacity,
    'joined', (select count(*) from participants p where p.challenge_id = c.id and p.status not in ('kicked', 'left')),
    'days', c.end_date - c.start_date + 1)
  from challenges c where c.invite_code = upper(p_code) and c.status in ('recruiting', 'checking', 'running')
$$;

-- 참가(05 API #3): 자격 게이트 + 기록 모드 + BMR 잠금. 사유는 profiles 에만(비공개).
-- p: {code, nickname, sex, birth_year, height_cm, weight_kg, pregnancy?, eating_disorder?, consents:{terms, sensitive_health, overseas_ai}}
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
  union all select v_uid, 'overseas_ai', v_ver where coalesce((p #>> '{consents,overseas_ai}')::boolean, false);

  insert into participants (challenge_id, user_id, nickname, sex, birth_year, age, height_cm, weight_locked, bmr_locked, status, rank_eligible)
  values (ch.id, v_uid, p ->> 'nickname', (p ->> 'sex')::sex_type, (p ->> 'birth_year')::int, v_age, (p ->> 'height_cm')::numeric,
    (p ->> 'weight_kg')::numeric, v_bmr, case when v_reason is null then 'active' else 'record_mode' end, v_reason is null)
  on conflict (challenge_id, user_id) do update set nickname = excluded.nickname
  returning * into v_part;

  return jsonb_build_object('participant_id', v_part.id, 'challenge_id', ch.id, 'bmr', v_bmr,
    'm_p', m_p(v_bmr, engine_rules(ch.id)), 'f_p', f_p(v_bmr, engine_rules(ch.id)), 'record_mode', v_reason is not null);
end $$;

-- 음식 검색(05 API #14): 동의어 → pg_trgm, 상위 10
create or replace function food_search(q text) returns table (food_code text, name_kr text, kcal numeric, serving_g numeric, score real)
  language sql stable as $$
  with cand as (
    select f.food_code, f.name_kr, f.kcal, f.serving_g, similarity(f.name_kr, q) as score from food_db_cache f
    where f.name_kr % q or f.name_kr ilike '%' || q || '%'
    union all
    select f.food_code, f.name_kr, f.kcal, f.serving_g, similarity(s.alias, q) * s.weight from food_synonyms s
    join food_db_cache f on f.food_code = s.food_code where s.alias % q or s.alias = q
  )
  select food_code, name_kr, kcal, serving_g, max(score)::real from cand group by 1, 2, 3, 4 order by 5 desc, 2 limit 10
$$;

-- 04 §4.2 매핑: 후보 3개 → 동의어 → trgm. ≥0.45 자동 / 0.25~0.45 후보 칩 / <0.25 미매칭
create or replace function map_food_candidates(p_candidates text[]) returns jsonb
  language plpgsql stable as $$
declare v_best record; v_chips jsonb;
begin
  select x.food_code, x.name_kr, x.kcal, x.score into v_best from (
    select r.*, row_number() over (order by r.score desc) rn from unnest(p_candidates) with ordinality c(name, ord),
      lateral food_search(c.name) r) x
  order by x.score desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('food_code', z.food_code, 'name', z.name_kr, 'kcal', z.kcal, 'score', z.score)), '[]')
  into v_chips from (
    select distinct on (r.food_code) r.* from unnest(p_candidates) c(name), lateral food_search(c.name) r
    order by r.food_code, r.score desc) z;
  return jsonb_build_object(
    'match', case when v_best.score >= 0.45 then 'auto' when v_best.score >= 0.25 then 'chips' else 'none' end,
    'food_code', case when v_best.score >= 0.45 then v_best.food_code end,
    'kcal', case when v_best.score >= 0.45 then v_best.kcal end,
    'score', v_best.score,
    'chips', (select coalesce(jsonb_agg(e order by (e ->> 'score')::numeric desc), '[]') from jsonb_array_elements(v_chips) e));
end $$;

-- ---------------------------------------------------------------- 함수 실행 권한
-- 기본은 막고, 클라이언트가 RPC로 부를 것만 연다. 배치·동기화·확정 함수는 service_role(Edge Function·pg_cron) 전용.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;
grant execute on function
  r1(numeric), round10(numeric), bmr_raw(sex_type, numeric, numeric, int), bmr_kcal(sex_type, numeric, numeric, int),
  default_rules(), engine_rules(uuid), m_p(int, challenge_rules), f_p(int, challenge_rules), run_met(numeric),
  session_met(text, numeric, numeric, challenge_rules), activity_kcal(numeric, int, jsonb, int, challenge_rules),
  intake_kcal(int, jsonb, int, challenge_rules), score_simulate(int, numeric, numeric, int, challenge_rules),
  score_simulate_from_inputs(jsonb), meal_item_kcal(numeric, numeric, int, boolean, numeric, challenge_rules),
  kst_date(timestamptz), kst_at(date, time), challenge_open_review_count(uuid),
  is_challenge_operator(uuid), is_challenge_member(uuid), owns_participant(uuid), operates_participant(uuid),
  join_challenge(jsonb), food_search(text), map_food_candidates(text[]),
  apply_verdict(uuid, verdict_type, boolean, uuid, text, timestamptz), transition_challenge(uuid, challenge_status, uuid, timestamptz),
  reason_sentence(text), verdict_message(text, verdict_type, jsonb), format_k1(numeric), format_signed1(numeric), format_md(date), josa_ro(text),
  write_audit(uuid, uuid, text, text, jsonb, jsonb, jsonb)
to authenticated;
grant execute on function get_invite(text), kst_date(timestamptz) to anon, authenticated;

-- 판정·전환은 운영자 확인 후 RLS를 넘어 쓰기가 필요 → security definer (함수 안에서 is_challenge_operator 검사)
alter function apply_verdict(uuid, verdict_type, boolean, uuid, text, timestamptz) security definer set search_path = public;
alter function transition_challenge(uuid, challenge_status, uuid, timestamptz) security definer set search_path = public;
-- 운영자 RPC 판정은 actor 를 본인으로 강제
create or replace function apply_verdict_rpc(p_review_id uuid, p_verdict verdict_type, p_dry_run boolean default true,
  p_reason_template text default null) returns jsonb
  language sql security definer set search_path = public as $$
  select apply_verdict(p_review_id, p_verdict, p_dry_run, auth.uid(), p_reason_template, now())
$$;
revoke execute on function apply_verdict(uuid, verdict_type, boolean, uuid, text, timestamptz) from authenticated;
revoke execute on function write_audit(uuid, uuid, text, text, jsonb, jsonb, jsonb) from authenticated;
grant execute on function apply_verdict_rpc(uuid, verdict_type, boolean, text) to authenticated;
-- 트리거 함수가 내부에서 쓰는 헬퍼
alter function write_audit(uuid, uuid, text, text, jsonb, jsonb, jsonb) security definer set search_path = public;
