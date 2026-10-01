-- 참가자 쓰기 경로 2차 (docs/05 API #8·#9·#10·#19·#22, §6 AI 파이프라인, §8 계정 삭제)
--   create_photo              서명 업로드 전 사진 행 생성(서버 수신 시각)
--   verify_photo              업로드 객체 재검증(sha256·bytes·해상도) → 불일치 photo_mismatch
--   create_meal               끼니 생성: 서버 KST 슬롯 태그 · 지연 업로드 규칙 · 중복 해시 dup_photo · 국외 AI 동의 → engine
--   create_manual_meal        사진 없는 직접 입력 끼니(확정값) · 1일 3건 이상 manual_input_burst
--   submit_report             익명 신고 → reviews(report) + review_reporters
--   delete_account            즉시 삭제·익명화(일별 점수만 보존)
-- 모두 service_role 전용(Edge Function 이 JWT 로 사용자 확인 후 p_user 를 넘긴다).

-- 탈퇴 참가자의 신체 정보는 비운다(05 §8 즉시 익명화) → NOT NULL 해제
alter table participants alter column sex drop not null, alter column birth_year drop not null, alter column age drop not null,
  alter column height_cm drop not null, alter column weight_locked drop not null, alter column bmr_locked drop not null;
alter table users add column deleted_at timestamptz;

-- 신고 대상도 소명할 수 있다(프로토타입 R-0417 '검토 중 · 소명 대기'). 결과 이의(objection)만 제외.
drop policy appeals_insert on appeals;
create policy appeals_insert on appeals for insert to authenticated
  with check (owns_participant(participant_id) and exists (
    select 1 from reviews r where r.id = review_id and r.participant_id = appeals.participant_id
      and r.status = 'open' and r.type <> 'objection' and now() <= coalesce(r.sla_due_at, r.created_at + interval '72 hours')));

-- 참가 중인 챌린지(진행 단계) 1건
create or replace function active_participant(p_user uuid, p_statuses challenge_status[] default array['checking', 'running']::challenge_status[])
  returns participants language sql stable as $$
  select p.* from participants p join challenges c on c.id = p.challenge_id
  where p.user_id = p_user and c.status = any (p_statuses) and p.status in ('active', 'record_mode', 'excluded')
  order by p.joined_at desc limit 1
$$;

-- KST 시각 → 끼니 슬롯(04 §4.3, 경계는 challenge_rules)
create or replace function slot_for(p_ts timestamptz, p_rules challenge_rules) returns meal_slot
  language sql immutable as $$
  select case
    when t >= p_rules.breakfast_start and t < p_rules.breakfast_end then 'breakfast'
    when t >= p_rules.breakfast_end and t < p_rules.lunch_end then 'lunch'
    when t >= p_rules.lunch_end and t < p_rules.dinner_end then 'dinner'
    else 'snack' end::meal_slot
  from (select (p_ts at time zone 'Asia/Seoul')::time as t) x
$$;

-- ---------------------------------------------------------------- 사진 (API #8)
create or replace function create_photo(p_user uuid, p_sha256 text, p_bytes int, p_width int, p_height int,
  p_client_captured_at timestamptz, p_now timestamptz default now()) returns jsonb
  language plpgsql as $$
declare p participants; v_id uuid := gen_random_uuid(); v_path text;
begin
  p := active_participant(p_user);
  if p.id is null then raise exception '진행 중인 챌린지가 없어요' using errcode = 'PT403'; end if;
  if p_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'sha256: 소문자 hex 64자' using errcode = 'PT422'; end if;
  if p_bytes is null or p_bytes <= 0 or p_bytes > 3 * 1024 * 1024 then raise exception 'bytes: 1~3 MB' using errcode = 'PT422'; end if;
  if greatest(p_width, p_height) > 1568 or least(p_width, p_height) < 64 then
    raise exception '해상도: 긴 변 1,568 px 이하로 리사이즈해 주세요' using errcode = 'PT422';
  end if;
  v_path := format('%s/%s/%s.jpg', p.challenge_id, p.id, v_id);
  insert into photos (id, participant_id, challenge_id, storage_path, sha256, width, height, bytes, client_captured_at, server_received_at)
  values (v_id, p.id, p.challenge_id, v_path, p_sha256, p_width, p_height, p_bytes, p_client_captured_at, p_now);
  return jsonb_build_object('photo_id', v_id, 'storage_path', v_path, 'server_received_at', p_now);
end $$;

-- 업로드된 객체를 Edge Function 이 읽어 잰 값으로 재검증(05 §6). 불일치 → photo_mismatch 플래그 + 422
create or replace function verify_photo(p_user uuid, p_photo uuid, p_sha256_server text, p_bytes int, p_width int, p_height int,
  p_now timestamptz default now()) returns jsonb
  language plpgsql as $$
declare ph photos; p participants;
begin
  select * into ph from photos where id = p_photo for update;
  if not found then raise exception 'photo not found' using errcode = 'PT404'; end if;
  select * into p from participants where id = ph.participant_id;
  if p.user_id is distinct from p_user then raise exception 'not your photo' using errcode = 'PT403'; end if;
  if ph.verified_at is not null then
    return jsonb_build_object('photo_id', ph.id, 'verified', true, 'sha256_server', ph.sha256_server);
  end if;
  if p_sha256_server is distinct from ph.sha256 or p_bytes is distinct from ph.bytes
     or p_width is distinct from ph.width or p_height is distinct from ph.height then
    perform raise_flag(p.id, kst_date(p_now), 'photo_mismatch', jsonb_build_object('key', ph.id::text, 'photo_id', ph.id,
      'reported', jsonb_build_object('sha256', ph.sha256, 'bytes', ph.bytes, 'w', ph.width, 'h', ph.height),
      'measured', jsonb_build_object('sha256', p_sha256_server, 'bytes', p_bytes, 'w', p_width, 'h', p_height)), p_now);
    return jsonb_build_object('photo_id', ph.id, 'verified', false);
  end if;
  update photos set sha256_server = p_sha256_server, verified_at = p_now where id = ph.id;
  return jsonb_build_object('photo_id', ph.id, 'verified', true, 'sha256_server', p_sha256_server);
end $$;

-- ---------------------------------------------------------------- 끼니 생성 (API #9, 05 §6 지연 업로드)
-- 태그 기준은 서버 수신 시각. 예외(queued=true, 단말 촬영 시각 기준 차이 d):
--   d ≤ 30분            → 서버 시각, 플래그 없음
--   단말 날짜가 확정됨   → 끼니 미인정(counted=false, status captured 유지, 사진·해시만 보존) + late_upload
--   30분 < d ≤ 12시간   → 단말 시각으로 태그 + late_upload 배지·플래그
--   d > 12시간          → 서버 시각 + late_upload 플래그
create or replace function create_meal(p_user uuid, p_photo uuid, p_queued boolean default false, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  ph photos; p participants; ch challenges; r challenge_rules;
  v_tag_at timestamptz := p_now;
  v_diff interval;
  v_late boolean := false;
  v_counted boolean := true;
  v_date date; v_slot meal_slot;
  v_engine ai_engine := 'none';
  v_meal uuid;
  v_dup boolean;
begin
  select * into ph from photos where id = p_photo;
  if not found then raise exception 'photo not found' using errcode = 'PT404'; end if;
  select * into p from participants where id = ph.participant_id;
  if p.user_id is distinct from p_user then raise exception 'not your photo' using errcode = 'PT403'; end if;
  if ph.verified_at is null then raise exception '사진 업로드 확인 전이에요' using errcode = 'PT422'; end if;
  if exists (select 1 from meals where photo_id = p_photo) then
    return (select jsonb_build_object('meal_id', id, 'status', status, 'local_date', local_date, 'slot', slot, 'replayed', true)
      from meals where photo_id = p_photo);
  end if;
  select * into ch from challenges where id = p.challenge_id;
  r := engine_rules(ch.id);

  if p_queued and ph.client_captured_at is not null and ph.client_captured_at < p_now then
    v_diff := p_now - ph.client_captured_at;
    if v_diff > interval '30 minutes' then
      v_late := true;
      if exists (select 1 from daily_scores where participant_id = p.id and local_date = kst_date(ph.client_captured_at) and is_final) then
        v_tag_at := ph.client_captured_at; v_counted := false;
      elsif v_diff <= r.late_upload_window then
        v_tag_at := ph.client_captured_at;
      end if;
    end if;
  end if;
  v_date := kst_date(v_tag_at);
  v_slot := slot_for(v_tag_at, r);
  if v_counted and (v_date < ch.start_date or v_date > ch.end_date) then
    raise exception '챌린지 기간 밖의 사진이에요' using errcode = 'PT422';
  end if;
  if v_counted and exists (select 1 from daily_scores where participant_id = p.id and local_date = v_date and is_final) then
    v_counted := false; -- 확정된 날짜로 태그되는 경우(서버 시각 기준)도 미인정
  end if;
  if exists (select 1 from consents where user_id = p_user and type = 'overseas_ai' and revoked_at is null) then
    v_engine := 'gemini';
  end if;

  insert into meals (participant_id, challenge_id, local_date, slot, status, photo_id, engine, late_upload, counted, captured_at)
  values (p.id, p.challenge_id, v_date, v_slot, 'captured', p_photo, v_engine, v_late, v_counted, p_now)
  returning id into v_meal;

  if v_late then
    perform raise_flag(p.id, v_date, 'late_upload', jsonb_build_object('key', v_meal::text, 'meal_id', v_meal,
      'client_captured_at', ph.client_captured_at, 'server_received_at', p_now, 'counted', v_counted), p_now);
  end if;
  -- 사진 SHA-256 중복(본인·타인, 서버 해시 기준) → dup_photo 검토 중
  select exists (select 1 from photos o where o.sha256_server = ph.sha256_server and o.id <> ph.id) into v_dup;
  if v_dup then
    perform raise_flag(p.id, v_date, 'dup_photo', jsonb_build_object('key', v_meal::text, 'meal_id', v_meal, 'photo_id', p_photo), p_now);
  end if;
  if v_counted then perform recompute_day(p.id, v_date); end if;

  return jsonb_build_object('meal_id', v_meal, 'status', 'captured', 'local_date', v_date, 'slot', v_slot, 'engine', v_engine,
    'late_upload', v_late, 'counted', v_counted, 'dup_photo', v_dup, 'analyze', v_engine <> 'none' and v_counted);
end $$;

-- ---------------------------------------------------------------- 직접 입력 끼니 (API #10)
-- 사진 없는 확정 끼니. items 형식은 confirm_meal 과 같다. 하루 3건 이상 → manual_input_burst 플래그(값 유지)
create or replace function create_manual_meal(p_user uuid, p_slot meal_slot, p_items jsonb, p_local_date date default null,
  p_now timestamptz default now()) returns jsonb
  language plpgsql as $$
declare p participants; ch challenges; v_date date := coalesce(p_local_date, kst_date(p_now)); v_meal uuid; r jsonb; v_n int;
begin
  p := active_participant(p_user);
  if p.id is null then raise exception '진행 중인 챌린지가 없어요' using errcode = 'PT403'; end if;
  select * into ch from challenges where id = p.challenge_id;
  if v_date > kst_date(p_now) or v_date < kst_date(p_now) - 2 or v_date < ch.start_date or v_date > ch.end_date then
    raise exception '오늘부터 이틀 전까지만 입력할 수 있어요' using errcode = 'PT422';
  end if;
  if exists (select 1 from daily_scores where participant_id = p.id and local_date = v_date and is_final) then
    raise exception '확정된 날짜예요' using errcode = 'PT422';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'items 가 비었어요' using errcode = 'PT422'; end if;
  insert into meals (participant_id, challenge_id, local_date, slot, status, engine, captured_at)
  values (p.id, p.challenge_id, v_date, p_slot, 'captured', 'none', p_now) returning id into v_meal;
  r := confirm_meal(p_user, v_meal,
    (select jsonb_agg(x || jsonb_build_object('input_type', coalesce(x ->> 'input_type', 'manual'))) from jsonb_array_elements(p_items) x),
    1, p_now);
  select count(*) into v_n from meals m where m.participant_id = p.id and m.local_date = v_date and m.photo_id is null
    and m.status in ('confirmed', 'corrected');
  if v_n >= 3 then
    perform raise_flag(p.id, v_date, 'manual_input_burst', jsonb_build_object('key', v_date::text, 'count', v_n), p_now);
  end if;
  return r || jsonb_build_object('local_date', v_date, 'slot', p_slot, 'manual_count_today', v_n);
end $$;

-- ---------------------------------------------------------------- 신고 (API #19)
-- 신고자는 reviews 에 남기지 않고 review_reporters(운영자 전용)에만. 하루 3건 상한, 같은 대상·날짜 중복은 기존 건 반환.
create or replace function submit_report(p_user uuid, p_target_participant uuid, p_meal uuid, p_reason text, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  me participants; t participants; m meals; v_date date; v_id uuid; v_today int; v_notif uuid; v_sched timestamptz;
begin
  me := active_participant(p_user, array['checking', 'running', 'closing']::challenge_status[]);
  if me.id is null then raise exception '진행 중인 챌린지가 없어요' using errcode = 'PT403'; end if;
  if p_meal is not null then
    select * into m from meals where id = p_meal;
    if not found then raise exception 'meal not found' using errcode = 'PT404'; end if;
    p_target_participant := m.participant_id; v_date := m.local_date;
  end if;
  select * into t from participants where id = p_target_participant;
  if not found or t.challenge_id <> me.challenge_id then raise exception '같은 챌린지 참가자만 신고할 수 있어요' using errcode = 'PT404'; end if;
  if t.id = me.id then raise exception '본인은 신고할 수 없어요' using errcode = 'PT422'; end if;
  if char_length(coalesce(trim(p_reason), '')) not between 2 and 500 then raise exception '사유를 2~500자로 적어 주세요' using errcode = 'PT422'; end if;
  v_date := coalesce(v_date, kst_date(p_now));

  select r.id into v_id from reviews r join review_reporters rr on rr.review_id = r.id
  where r.type = 'report' and r.participant_id = t.id and r.local_date = v_date and rr.reporter_participant_id = me.id
    and r.target ->> 'meal_id' is not distinct from p_meal::text;
  if v_id is not null then return jsonb_build_object('review_id', v_id, 'replayed', true); end if;
  select count(*) into v_today from review_reporters rr where rr.reporter_participant_id = me.id and kst_date(rr.created_at) = kst_date(p_now);
  if v_today >= 3 then raise exception '신고는 하루 3건까지 할 수 있어요' using errcode = 'PT429'; end if;

  insert into reviews (challenge_id, participant_id, type, local_date, target, created_at)
  values (t.challenge_id, t.id, 'report', v_date,
    jsonb_strip_nulls(jsonb_build_object('meal_id', p_meal, 'slot', m.slot)), p_now)
  returning id into v_id;
  insert into review_reporters (review_id, reporter_participant_id, reason, created_at) values (v_id, me.id, trim(p_reason), p_now);
  -- 당사자에게는 신고자·사유 없이 N-05 만(소명 72h 기산)
  v_notif := enqueue_notification(t.user_id, t.challenge_id, 'N-05', '기록 확인 안내',
    '기록을 확인 중이에요. 72시간 안에 설명을 남길 수 있어요', jsonb_build_object('review_id', v_id), p_now);
  select scheduled_at into v_sched from notifications where id = v_notif;
  update reviews set notified_at = coalesce(v_sched, p_now), sla_due_at = coalesce(v_sched, p_now) + interval '72 hours' where id = v_id;
  update daily_scores set under_review = true where participant_id = t.id and local_date = v_date;
  perform write_audit(t.challenge_id, null, 'system', 'report', jsonb_build_object('review_id', v_id, 'local_date', v_date));
  return jsonb_build_object('review_id', v_id, 'replayed', false);
end $$;

-- ---------------------------------------------------------------- 계정 삭제 (API #22, 05 §8)
-- 즉시 삭제: 사진(행·Storage 객체 경로 반환)·식사·항목·체중·기기·활동·세션·동기화·건강 알림·알림·프로필·동의
-- 즉시 익명화: users(provider·nickname 제거, status deleted), participants(nickname '탈퇴 참가자', 신체 정보 null, user_id null, status left),
--             daily_scores(분해값 null, s_d·local_date·is_counted 만 보존 → 타인 누적 순위 유지)
-- 판정 이력(reviews·appeals·audit_logs)은 익명 participant_id 로 유지. auth 사용자 비활성화·하드 삭제는 Edge Function 이 한다.
create or replace function delete_account(p_user uuid, p_confirm text, p_now timestamptz default now()) returns jsonb
  language plpgsql as $$
declare v_parts uuid[]; v_paths text[]; v_counts jsonb := '{}'; n int;
begin
  if p_confirm is distinct from '삭제' then raise exception '확인을 위해 "삭제"를 입력해 주세요' using errcode = 'PT422'; end if;
  if exists (select 1 from challenges where operator_id = p_user and status not in ('archived', 'cancelled')) then
    raise exception '운영 중인 챌린지가 있어 삭제할 수 없어요' using errcode = 'PT409';
  end if;
  select coalesce(array_agg(id), '{}') into v_parts from participants where user_id = p_user;

  select coalesce(array_agg(storage_path) filter (where purged_at is null), '{}') into v_paths from photos where participant_id = any (v_parts);
  delete from meals where participant_id = any (v_parts);                 -- meal_items cascade
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('meals', n);
  delete from photos where participant_id = any (v_parts);
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('photos', n);
  delete from weights where participant_id = any (v_parts);
  delete from activity_sessions where participant_id = any (v_parts);
  delete from daily_activity where participant_id = any (v_parts);
  get diagnostics n = row_count; v_counts := v_counts || jsonb_build_object('daily_activity', n);
  delete from sync_batches where participant_id = any (v_parts);
  delete from idempotency_keys where user_id = p_user or participant_id = any (v_parts);
  delete from health_alerts where participant_id = any (v_parts);
  delete from participant_notes where participant_id = any (v_parts);
  delete from cheers where from_participant_id = any (v_parts);
  delete from notifications where user_id = p_user;
  delete from devices where user_id = p_user;
  delete from consents where user_id = p_user;
  delete from profiles where user_id = p_user;

  update daily_scores set bmr = null, a_d = null, i_confirmed = null, i_snack = null, substitute_slots = null, m_p = null,
    i_d = null, f_p = null, d_d = null, breakdown = '{}'
  where participant_id = any (v_parts);
  update score_revisions set prev_breakdown = null where participant_id = any (v_parts);
  update participants set nickname = '탈퇴 참가자', sex = null, birth_year = null, age = null, height_cm = null,
    weight_locked = null, bmr_locked = null, baseline_median_steps = null, grade_badge = null, last_sync_source = null,
    status = 'left', user_id = null
  where id = any (v_parts);
  update users set nickname = null, provider = null, status = 'deleted', deleted_at = p_now where id = p_user;

  perform write_audit(p2.challenge_id, null, 'system', 'account_deleted', jsonb_build_object('participant_id', p2.id))
  from participants p2 where p2.id = any (v_parts);
  return jsonb_build_object('participants', cardinality(v_parts), 'storage_paths', to_jsonb(v_paths), 'deleted', v_counts);
end $$;

-- users 하드 삭제(05 §8: 30일 내) — auth.users 삭제는 Edge Function/관리 API 가, 여기서는 대상 목록만
create or replace function deleted_users_due(p_now timestamptz default now()) returns setof uuid
  language sql stable as $$ select id from users where status = 'deleted' and deleted_at < p_now - interval '30 days' $$;

-- Archived 시 탈퇴 참가자의 익명 점수 행 삭제(05 §8 [제안])
create or replace function purge_left_scores(p_challenge uuid) returns int language plpgsql as $$
declare n int;
begin
  delete from daily_scores d using participants p
  where p.id = d.participant_id and p.challenge_id = p_challenge and p.status = 'left' and p.user_id is null;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function build_leaderboard(p_challenge uuid, p_scope leaderboard_scope, p_date date, p_is_final boolean,
  p_as_of timestamptz default now())
  returns uuid language plpgsql as $$
declare v_rows jsonb; v_id uuid;
begin
  with base as (
    select p.id, p.nickname, p.grade_badge, p.grade_badge_public,
      case when p_scope = 'today' then ds.s_d else (select coalesce(sum(x.s_d), 0) from daily_scores x
        where x.participant_id = p.id and x.is_counted and x.is_final and x.local_date <= p_date) end as score,
      case when p_scope = 'today' then coalesce(ds.main_meal_count, 0) else (select coalesce(sum(x.main_meal_count), 0) from daily_scores x
        where x.participant_id = p.id and x.is_counted and x.is_final and x.local_date <= p_date) end as meals,
      exists (select 1 from reviews rv where rv.participant_id = p.id and rv.status in ('open', 'appealed')
        and rv.type not in ('session_anomaly', 'manual_input_burst', 'late_upload', 'photo_mismatch', 'objection')) as under_review,
      -- 반영률 4칸: 아침·점심·저녁 확정 + 활동 동기화(표시 전용, 05 §5.3)
      (select count(*) from (select distinct m.slot from meals m where m.participant_id = p.id and m.local_date = p_date
         and m.slot <> 'snack' and m.counted and m.status in ('confirmed', 'auto', 'corrected') and m.confirmed_kcal >= 150) z)
        + case when exists (select 1 from daily_activity a where a.participant_id = p.id and a.local_date = p_date and a.synced_at is not null) then 1 else 0 end as fill,
      (select count(*) from cheers c where c.to_participant_id = p.id and c.local_date = p_date) as cheer_count
    from participants p
    left join daily_scores ds on ds.participant_id = p.id and ds.local_date = p_date
    where p.challenge_id = p_challenge and p.rank_eligible and p.leaderboard_visible
      and (p.status = 'active' or (p.status = 'left' and p.user_id is null)) -- 탈퇴 참가자: 익명 점수 유지(05 §8)
  ), ranked as (
    select *, rank() over (order by coalesce(score, 0) desc) as rnk,
      row_number() over (order by coalesce(score, 0) desc, meals desc, nickname) as ord
    from base
  ), tied as (
    select *, count(*) over (partition by rnk) > 1 as tie from ranked
  )
  select coalesce(jsonb_agg(case when under_review then
      jsonb_build_object('rank', rnk, 'aggregating', true, 'fill', 0)
    else jsonb_build_object('rank', rnk, 'participant_id', id, 'nickname', nickname, 'score', coalesce(score, 0),
      'fill', fill, 'cheer_count', cheer_count, 'badge', case when grade_badge_public then grade_badge end,
      'tie', tie)
    end order by ord), '[]')
  into v_rows from tied;

  insert into leaderboard_snapshots (challenge_id, scope, local_date, as_of, is_final, rows)
  values (p_challenge, p_scope, p_date, p_as_of, p_is_final, v_rows) returning id into v_id;
  return v_id;
end $$;

-- Archived 전환 시 탈퇴 참가자 점수 정리
create or replace function challenges_archived_cleanup() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'archived' and old.status is distinct from 'archived' then perform purge_left_scores(new.id); end if;
  return new;
end $$;
create trigger challenges_archived after update of status on challenges for each row execute function challenges_archived_cleanup();

revoke execute on function active_participant(uuid, challenge_status[]), slot_for(timestamptz, challenge_rules),
  create_photo(uuid, text, int, int, int, timestamptz, timestamptz), verify_photo(uuid, uuid, text, int, int, int, timestamptz),
  create_meal(uuid, uuid, boolean, timestamptz), create_manual_meal(uuid, meal_slot, jsonb, date, timestamptz),
  submit_report(uuid, uuid, uuid, text, timestamptz), delete_account(uuid, text, timestamptz), deleted_users_due(timestamptz),
  purge_left_scores(uuid)
  from public, anon, authenticated;
grant execute on function active_participant(uuid, challenge_status[]), slot_for(timestamptz, challenge_rules),
  create_photo(uuid, text, int, int, int, timestamptz, timestamptz), verify_photo(uuid, uuid, text, int, int, int, timestamptz),
  create_meal(uuid, uuid, boolean, timestamptz), create_manual_meal(uuid, meal_slot, jsonb, date, timestamptz),
  submit_report(uuid, uuid, uuid, text, timestamptz), delete_account(uuid, text, timestamptz), deleted_users_due(timestamptz),
  purge_left_scores(uuid)
  to service_role;
