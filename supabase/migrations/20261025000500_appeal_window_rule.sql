-- 소명 기한을 챌린지 규칙(challenge_rules.appeal_window, 기본 72시간)에서 읽는다(지금까지 72시간 고정).
-- 검토 열기(raise_flag)·신고(submit_report)는 기한(sla_due_at)과 N-05 문구의 시간을 규칙값으로,
-- 소명 입력 권한(appeals_insert)은 기한이 없는 오래된 검토도 규칙값으로 판단한다.
-- 이의 제기(objection)의 72시간은 운영자 답변 기한이라 그대로 둔다. 함수 본문은 20261001000300 · 20261001000700 그대로, 기한 부분만 바꿈.

create or replace function raise_flag(p_participant uuid, p_date date, p_type review_type, p_target jsonb, p_now timestamptz default now())
  returns uuid language plpgsql as $$
declare
  p participants;
  v_id uuid;
  v_notify boolean := p_type in ('steps_spike', 'source_unknown', 'dup_photo', 'downward_edit', 'skip_abuse', 'multi_device');
  v_notif uuid;
  v_sched timestamptz;
  v_win interval;
  v_hrs text;
begin
  select * into p from participants where id = p_participant;
  v_win := (engine_rules(p.challenge_id)).appeal_window;
  v_hrs := round(extract(epoch from v_win) / 3600)::int::text;
  insert into reviews (challenge_id, participant_id, type, local_date, target, reason_template)
  values (p.challenge_id, p_participant, p_type, p_date, coalesce(p_target, '{}'),
    case when p_type in ('steps_spike', 'source_unknown', 'dup_photo', 'downward_edit', 'skip_abuse') then p_type::text end)
  on conflict (participant_id, type, local_date, coalesce(target ->> 'key', '')) where type not in ('report', 'objection')
  do nothing
  returning id into v_id;
  if v_id is null then return null; end if;

  if v_notify then
    -- N-05 검토 안내·소명 요청. 소명 기한(규칙 appeal_window) 는 N-05 발송 시각 기산(22~08시 생성분은 08:00 발송)
    v_notif := enqueue_notification(p.user_id, p.challenge_id, 'N-05', '기록 확인 안내',
      format('기록을 확인 중이에요. %s시간 안에 설명을 남길 수 있어요', v_hrs), jsonb_build_object('review_id', v_id), p_now);
    select scheduled_at into v_sched from notifications where id = v_notif;
    update reviews set notified_at = coalesce(v_sched, p_now), sla_due_at = coalesce(v_sched, p_now) + v_win where id = v_id;
    update daily_scores set under_review = true where participant_id = p_participant and local_date = p_date;
  else
    update reviews set sla_due_at = p_now + v_win where id = v_id;
  end if;
  perform write_audit(p.challenge_id, null, 'system', 'flag', jsonb_build_object('review_id', v_id, 'type', p_type, 'local_date', p_date));
  return v_id;
end $$;

create or replace function submit_report(p_user uuid, p_target_participant uuid, p_meal uuid, p_reason text, p_now timestamptz default now())
  returns jsonb language plpgsql as $$
declare
  me participants; t participants; m meals; v_date date; v_id uuid; v_today int; v_notif uuid; v_sched timestamptz; v_win interval; v_hrs text;
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
  v_win := (engine_rules(t.challenge_id)).appeal_window;
  v_hrs := round(extract(epoch from v_win) / 3600)::int::text;

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
  -- 당사자에게는 신고자·사유 없이 N-05 만(소명 기한(규칙 appeal_window) 기산)
  v_notif := enqueue_notification(t.user_id, t.challenge_id, 'N-05', '기록 확인 안내',
    format('기록을 확인 중이에요. %s시간 안에 설명을 남길 수 있어요', v_hrs), jsonb_build_object('review_id', v_id), p_now);
  select scheduled_at into v_sched from notifications where id = v_notif;
  update reviews set notified_at = coalesce(v_sched, p_now), sla_due_at = coalesce(v_sched, p_now) + v_win where id = v_id;
  update daily_scores set under_review = true where participant_id = t.id and local_date = v_date;
  perform write_audit(t.challenge_id, null, 'system', 'report', jsonb_build_object('review_id', v_id, 'local_date', v_date));
  return jsonb_build_object('review_id', v_id, 'replayed', false);
end $$;

drop policy appeals_insert on appeals;
create policy appeals_insert on appeals for insert to authenticated
  with check (owns_participant(participant_id) and exists (
    select 1 from reviews r where r.id = review_id and r.participant_id = appeals.participant_id
      and r.status = 'open' and r.type <> 'objection'
      and now() <= coalesce(r.sla_due_at, r.created_at + (engine_rules(r.challenge_id)).appeal_window)));
