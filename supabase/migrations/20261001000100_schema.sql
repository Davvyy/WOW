-- 챌로리 스키마 (docs/05 §3 ERD)
-- 참가자 데이터는 전부 challenge_id 가 1급 키. 공통 id uuid PK, created_at, updated_at.
-- kcal·점수는 numeric, BMR 은 10 kcal 단위 정수(04 §2).

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

-- ---------------------------------------------------------------- enums
create type challenge_status as enum ('draft', 'recruiting', 'checking', 'running', 'closing', 'published', 'archived', 'cancelled');
create type sex_type as enum ('M', 'F');
create type participant_status as enum ('active', 'record_mode', 'excluded', 'kicked', 'left');
create type record_mode_reason as enum ('minor', 'bmi', 'pregnancy', 'eating_disorder');
create type consent_type as enum ('terms', 'sensitive_health', 'overseas_ai');
create type push_permission as enum ('granted', 'denied', 'not_asked');
create type meal_slot as enum ('breakfast', 'lunch', 'dinner', 'snack');
create type meal_status as enum ('captured', 'draft', 'failed', 'confirmed', 'auto', 'corrected', 'void', 'skipped');
create type ai_engine as enum ('gemini', 'claude', 'none');
create type meal_input_type as enum ('ai', 'search', 'manual', 'recent');
create type portion_bucket as enum ('half', 'one', 'large');
create type confidence_level as enum ('high', 'mid', 'low');
create type session_type as enum ('running', 'stair', 'walking');
create type weight_source as enum ('manual', 'health_app');
create type review_type as enum ('steps_spike', 'source_unknown', 'dup_photo', 'downward_edit', 'skip_abuse',
  'session_anomaly', 'manual_input_burst', 'multi_device', 'late_upload', 'photo_mismatch', 'report', 'objection');
create type review_status as enum ('open', 'appealed', 'decided');
create type verdict_type as enum ('approve', 'warn', 'void', 'exclude');
create type revision_reason as enum ('user_edit', 'verdict', 'late_sync', 'auto_confirm');
create type health_alert_type as enum ('low_intake_3d', 'high_activity_3d', 'weight_drop');
create type notification_type as enum ('N-01', 'N-02', 'N-03', 'N-04', 'N-05', 'N-06', 'N-07');
create type notification_category as enum ('transactional', 'scheduled');
create type leaderboard_scope as enum ('today', 'cumulative');

-- ---------------------------------------------------------------- 공통 트리거
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------- 계정
create table users (
  id uuid primary key references auth.users (id) on delete cascade,
  provider text,
  nickname text,
  status text not null default 'active' check (status in ('active', 'deleted')),
  is_operator boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table profiles (
  user_id uuid primary key references users (id) on delete cascade,
  sex sex_type not null,
  birth_year int not null check (birth_year between 1900 and 2100),
  height_cm numeric(5,1) not null check (height_cm between 100 and 250),
  weight_kg numeric(5,1) not null check (weight_kg between 25 and 300),
  bmr_age int not null check (bmr_age between 0 and 130), -- BMR 나이 = 기준(챌린지 시작) 연도 − 출생 연도
  -- 04 §2: BMR_raw 를 10 kcal 단위 half-up 정수. 챌린지 산식은 참가 시 복사한 participants.bmr_locked 를 쓴다.
  bmr_kcal integer generated always as (
    (floor((10 * weight_kg + 6.25 * height_cm - 5 * bmr_age + case when sex = 'M' then 5 else -161 end) / 10 + 0.5) * 10)::int
  ) stored,
  record_mode boolean not null default false,
  record_mode_reason record_mode_reason, -- 운영자·타인 비공개. 저장 암호화는 Supabase Vault/pgsodium 도입 시 전환(TODO)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users (id) on delete cascade,
  type consent_type not null,
  version text not null,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index consents_user_idx on consents (user_id, type);

create table devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users (id) on delete cascade,
  platform text not null check (platform in ('ios', 'android')),
  push_token text,
  push_permission push_permission not null default 'not_asked',
  app_version text,
  integrity_verdict text, -- Play Integrity/App Attest 예약(v1 미사용)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index devices_user_idx on devices (user_id);

-- ---------------------------------------------------------------- 챌린지
create table challenges (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  status challenge_status not null default 'draft',
  start_date date not null,
  end_date date not null,
  capacity int not null check (capacity > 0),
  invite_code char(6) unique,
  rules_md text not null default '',
  operator_id uuid not null references users (id),
  published_at timestamptz,
  photos_purged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date >= start_date),
  check (invite_code ~ '^[A-Z0-9]{6}$')
);
create index challenges_operator_idx on challenges (operator_id);
create index challenges_status_idx on challenges (status);

-- 04 §5.2 상수. Checking 진입 시 locked_at.
create table challenge_rules (
  challenge_id uuid primary key references challenges (id) on delete cascade,
  t numeric not null default 500,
  c numeric not null default 1000,
  s_max numeric not null default 150,
  m_min numeric not null default 700,
  m_ratio numeric not null default 0.45,
  f_min numeric not null default 1200,
  f_ratio numeric not null default 0.8,
  auto_confirm numeric not null default 1.3,
  nudge_min_m numeric not null default 1500,
  nudge_min_f numeric not null default 1200,
  snack_kcal numeric not null default 150,
  steps_cap int not null default 30000,
  floors_cap int not null default 50,
  step_met numeric not null default 3.8,
  stair_met numeric not null default 6.8,
  sec_per_floor numeric not null default 17.5,
  broth_factor numeric not null default 0.6,
  skip_per_day int not null default 1,
  skip_per_week int not null default 3,
  check_days int not null default 3,
  steps_spike_abs int not null default 25000,
  steps_spike_ratio numeric not null default 2.5,
  breakfast_start time not null default '04:00',
  breakfast_end time not null default '10:30',
  lunch_end time not null default '15:00',
  dinner_end time not null default '22:00',
  late_upload_window interval not null default '12 hours',
  edit_window interval not null default '48 hours',
  appeal_window interval not null default '72 hours',
  finalize_time time not null default '09:00',
  origin_whitelist text[] not null default array[
    'com.apple.health', 'com.sec.android.app.shealth', 'android', 'com.google.android.apps.healthdata',
    'com.garmin.android.apps.connectmobile', 'com.fitbit.FitbitMobile', 'com.huami.watch.hmwatchmanager', 'com.xiaomi.wearable'],
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table teams (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references challenges (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table participants (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references challenges (id) on delete cascade,
  user_id uuid references users (id) on delete set null, -- 탈퇴 시 익명화(05 §8)
  nickname text not null,
  sex sex_type not null,
  birth_year int not null,
  age int not null,                 -- BMR 나이 = 시작 연도 − 출생 연도
  height_cm numeric(5,1) not null,
  weight_locked numeric(5,1) not null,
  bmr_locked int not null,          -- round10 정수(04 §2)
  status participant_status not null default 'active',
  rank_eligible boolean not null default true,
  warning_count int not null default 0,
  baseline_median_steps int,
  grade_badge text,
  grade_badge_public boolean not null default false,
  leaderboard_visible boolean not null default true,
  block_rejoin boolean not null default false,
  team_id uuid references teams (id) on delete set null,
  last_synced_at timestamptz,
  last_sync_source text,
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (challenge_id, user_id)
);
create index participants_challenge_idx on participants (challenge_id, status);
create index participants_user_idx on participants (user_id);

-- 운영자 메모는 참가자 본인 행 RLS 와 분리(구현 중 결정, docs/02 §10 참조)
create table participant_notes (
  participant_id uuid primary key references participants (id) on delete cascade,
  challenge_id uuid not null references challenges (id) on delete cascade,
  operator_note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- 동기화·멱등성
create table sync_batches (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants (id) on delete cascade,
  device_id uuid references devices (id) on delete set null,
  client_batch_id uuid not null unique,
  request_hash text,
  result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid references participants (id) on delete cascade,
  user_id uuid references users (id) on delete cascade,
  key uuid not null,
  endpoint text not null,
  request_hash text not null,
  status_code int,
  response jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, key)
);
create index idempotency_keys_created_idx on idempotency_keys (created_at);

create table daily_activity (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants (id) on delete cascade,
  challenge_id uuid not null references challenges (id) on delete cascade,
  local_date date not null,
  steps_total int not null default 0 check (steps_total >= 0),
  steps_manual int check (steps_manual >= 0),         -- null = 미지원(Android)
  has_manual_source boolean not null default false,
  steps_in_sessions int not null default 0,
  steps_excluded int not null default 0,              -- source_unknown 무효 판정으로 제외한 걸음
  steps_out_override int,                             -- steps_spike 무효 판정: 기준선 중앙값
  distance_m numeric,
  floors int,                                         -- null = 레코드 없음(카드 숨김)
  platform_active_kcal numeric,                       -- 참고값, 순위 미사용
  sources jsonb not null default '[]',
  steps_net_kcal numeric,
  sessions_net_kcal numeric,
  floors_kcal numeric,
  a_raw numeric,
  a_capped numeric,
  late_delta jsonb,                                   -- 확정 뒤 도착한 값(자동 반영 없음)
  synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (participant_id, local_date)
);
create index daily_activity_challenge_date_idx on daily_activity (challenge_id, local_date);

create table activity_sessions (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants (id) on delete cascade,
  challenge_id uuid not null references challenges (id) on delete cascade,
  local_date date not null,
  platform_uid text not null,
  type session_type not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  steps_in_range int not null default 0,
  distance_m numeric,
  avg_speed_kmh numeric,
  met numeric,
  net_kcal numeric,
  origin text,
  recording_method text,
  is_counted boolean not null default true,
  excluded_reason text,
  merged_into_id uuid references activity_sessions (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (participant_id, platform_uid, local_date),
  check (end_at > start_at)
);
create index activity_sessions_day_idx on activity_sessions (participant_id, local_date);

-- ---------------------------------------------------------------- 식사
create table photos (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants (id) on delete cascade,
  challenge_id uuid not null references challenges (id) on delete cascade,
  storage_path text not null,
  sha256 text not null,              -- 클라이언트 보고
  width int, height int, bytes int,
  client_captured_at timestamptz,    -- 기기 시각(참고)
  server_received_at timestamptz not null default now(),
  sha256_server text,
  verified_at timestamptz,
  purged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index photos_sha_idx on photos (sha256_server) where sha256_server is not null;
create index photos_challenge_idx on photos (challenge_id);

create table meals (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants (id) on delete cascade,
  challenge_id uuid not null references challenges (id) on delete cascade,
  local_date date not null,
  slot meal_slot not null,
  status meal_status not null default 'captured',
  photo_id uuid references photos (id) on delete set null,
  engine ai_engine not null default 'none',
  ai_kcal numeric,
  confirmed_kcal numeric,
  delta_ratio numeric,
  is_main boolean generated always as (coalesce(confirmed_kcal, 0) >= 150) stored,
  title text,
  items_hash text,                       -- 확정 항목 해시(동일 내용 재전송 시 revision 미생성)
  late_upload boolean not null default false,
  counted boolean not null default true,  -- false: is_final 날짜로 지연 업로드된 끼니(미인정)
  captured_at timestamptz not null default now(),
  confirmed_at timestamptz,
  version int not null default 1,
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index meals_photo_uidx on meals (photo_id) where photo_id is not null;
create unique index meals_skip_uidx on meals (participant_id, local_date, slot) where status = 'skipped';
create index meals_day_idx on meals (participant_id, local_date);
create index meals_challenge_status_idx on meals (challenge_id, status);

create table food_db_cache (
  food_code text primary key,
  name_kr text not null,
  category text,
  serving_g numeric,
  kcal numeric not null,
  carb_g numeric, protein_g numeric, fat_g numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index food_db_cache_name_trgm on food_db_cache using gin (name_kr gin_trgm_ops);

create table food_synonyms (
  id uuid primary key default gen_random_uuid(),
  alias text not null,
  food_code text not null references food_db_cache (food_code) on delete cascade,
  weight numeric not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (alias, food_code)
);
create index food_synonyms_alias_trgm on food_synonyms using gin (alias gin_trgm_ops);

create table meal_items (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid not null references meals (id) on delete cascade,
  name_candidates text[] not null default '{}',
  chosen_name text,
  food_code text references food_db_cache (food_code),
  input_type meal_input_type not null default 'ai',
  count int not null default 1 check (count >= 1),
  portion_bucket portion_bucket,
  portion_multiplier numeric(3,2) not null default 1.0 check (portion_multiplier between 0.25 and 2.0),
  broth_off boolean not null default false,
  bite_fraction numeric not null default 1,
  eaten boolean not null default true,
  confidence confidence_level,
  match_score numeric,
  needs_check boolean not null default false,
  ai_kcal numeric,
  confirmed_kcal numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index meal_items_meal_idx on meal_items (meal_id);

create table weights (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants (id) on delete cascade,
  challenge_id uuid not null references challenges (id) on delete cascade,
  local_date date not null,
  weight_kg numeric(5,1) not null,
  source weight_source not null default 'manual',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (participant_id, local_date, source)
);

-- ---------------------------------------------------------------- 점수·리더보드
create table daily_scores (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants (id) on delete cascade,
  challenge_id uuid not null references challenges (id) on delete cascade,
  local_date date not null,
  bmr int,
  a_d numeric,
  i_confirmed numeric,
  i_snack numeric,
  substitute_slots int,
  m_p numeric,
  i_d numeric,
  f_p numeric,
  d_d numeric(7,1),
  s_d numeric(5,1) not null default 0,
  main_meal_count int not null default 0,
  is_counted boolean not null default false,  -- 누적 반영(점검 기간 제외)
  is_final boolean not null default false,
  finalized_at timestamptz,
  under_review boolean not null default false,
  breakdown jsonb not null default '{}',
  computed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (participant_id, local_date)
);
create index daily_scores_challenge_date_idx on daily_scores (challenge_id, local_date);

create table score_revisions (
  id uuid primary key default gen_random_uuid(),
  daily_score_id uuid not null references daily_scores (id) on delete cascade,
  participant_id uuid not null references participants (id) on delete cascade,
  prev_s_d numeric(5,1),
  new_s_d numeric(5,1),
  prev_breakdown jsonb,
  reason revision_reason not null,
  review_id uuid,
  actor_id uuid references users (id) on delete set null,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index score_revisions_score_idx on score_revisions (daily_score_id);

create table leaderboard_snapshots (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references challenges (id) on delete cascade,
  scope leaderboard_scope not null,
  local_date date not null,
  as_of timestamptz not null default now(),
  is_final boolean not null default false,
  rows jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index leaderboard_snapshots_lookup_idx on leaderboard_snapshots (challenge_id, scope, as_of desc);

create table cheers (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references challenges (id) on delete cascade,
  from_participant_id uuid not null references participants (id) on delete cascade,
  to_participant_id uuid not null references participants (id) on delete cascade,
  local_date date not null default (now() at time zone 'Asia/Seoul')::date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (from_participant_id, local_date), -- 보내는 사람 기준 하루 1회
  check (from_participant_id <> to_participant_id)
);
create index cheers_to_idx on cheers (to_participant_id, local_date);

-- ---------------------------------------------------------------- 검토·판정
create table reviews (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references challenges (id) on delete cascade,
  participant_id uuid not null references participants (id) on delete cascade,
  type review_type not null,
  local_date date,
  target jsonb not null default '{}',      -- {meal_id, origin, steps, session_id, report_reason ...}
  status review_status not null default 'open',
  verdict verdict_type,
  reason_template text,
  notified_at timestamptz,                 -- N-05 발송 시각(소명 72h 기산)
  sla_due_at timestamptz,                  -- N-05 발송 + 72h
  score_impact jsonb,
  decided_at timestamptz,
  decided_by uuid references users (id) on delete set null,
  message text,                            -- 당사자 통지(사유+판정+점수 영향 문장)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index reviews_queue_idx on reviews (challenge_id, status, sla_due_at);
create index reviews_participant_idx on reviews (participant_id, local_date);
-- 같은 날·같은 대상의 자동 플래그 중복 생성 방지
create unique index reviews_auto_uidx on reviews (participant_id, type, local_date, coalesce(target ->> 'key', ''))
  where type not in ('report', 'objection');

-- 신고자는 당사자에게 비노출 → 별도 테이블(운영자 전용)
create table review_reporters (
  review_id uuid primary key references reviews (id) on delete cascade,
  reporter_participant_id uuid references participants (id) on delete set null,
  reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table appeals (
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null unique references reviews (id) on delete cascade, -- 소명 1회
  participant_id uuid not null references participants (id) on delete cascade,
  text text not null check (char_length(text) between 1 and 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table health_alerts (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants (id) on delete cascade,
  challenge_id uuid not null references challenges (id) on delete cascade,
  type health_alert_type not null,
  local_date date not null,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (participant_id, type, local_date)
);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users (id) on delete cascade,
  challenge_id uuid references challenges (id) on delete cascade,
  type notification_type not null,
  category notification_category not null,
  title text,
  body text not null,
  payload jsonb not null default '{}',
  scheduled_at timestamptz not null default now(),
  sent_at timestamptz,
  skipped_reason text,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index notifications_pending_idx on notifications (scheduled_at) where sent_at is null and skipped_reason is null;
create index notifications_user_idx on notifications (user_id, created_at desc);

create table audit_logs (
  id bigint generated always as identity primary key,
  challenge_id uuid references challenges (id) on delete set null,
  actor_id uuid references users (id) on delete set null,
  actor_role text not null,
  action text not null,
  target jsonb not null default '{}',
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now()
);
create index audit_logs_challenge_idx on audit_logs (challenge_id, created_at desc);

-- append-only
create or replace function audit_logs_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'audit_logs is append-only';
end $$;
create trigger audit_logs_no_update before update or delete on audit_logs
  for each row execute function audit_logs_append_only();

-- updated_at 트리거 일괄
do $$
declare t text;
begin
  foreach t in array array['users','profiles','consents','devices','challenges','challenge_rules','teams','participants',
    'participant_notes','sync_batches','idempotency_keys','daily_activity','activity_sessions','photos','meals','food_db_cache',
    'food_synonyms','meal_items','weights','daily_scores','score_revisions','leaderboard_snapshots','cheers','reviews',
    'review_reporters','appeals','health_alerts','notifications']
  loop
    execute format('create trigger %I before update on %I for each row execute function set_updated_at()', t || '_updated_at', t);
  end loop;
end $$;
