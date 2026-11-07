-- 건너뜀 하루 한도를 1회에서 2회로 올린다(docs/02 D84, 사용자 요청). 주 3회 한도는 그대로.
-- 새 챌린지는 기본값으로, 진행 중인 월간 챌린지는 규칙 행을 직접 바꾼다(잠금은 운영자 화면용이라 마이그레이션은 쓸 수 있다).
-- 집계가 끝났거나 끝나는 챌린지(closing 이후)는 그대로 둔다. 이미 확정된 날의 점수도 다시 계산하지 않는다.

alter table challenge_rules alter column skip_per_day set default 2;

create or replace function default_rules() returns challenge_rules
  language sql immutable as $$
  select jsonb_populate_record(null::challenge_rules, jsonb_build_object(
    't', 500, 'c', 1000, 's_max', 150, 'm_min', 700, 'm_ratio', 0.45, 'f_min', 1200, 'f_ratio', 0.8,
    'auto_confirm', 1.3, 'nudge_min_m', 1500, 'nudge_min_f', 1200, 'snack_kcal', 150,
    'steps_cap', 30000, 'floors_cap', 50, 'step_met', 3.8, 'stair_met', 6.8, 'sec_per_floor', 17.5,
    'broth_factor', 0.6, 'skip_per_day', 2, 'skip_per_week', 3, 'check_days', 3,
    'steps_spike_abs', 25000, 'steps_spike_ratio', 2.5, 'steps_spike_min', 15000,
    'breakfast_start', '04:00', 'breakfast_end', '10:30', 'lunch_end', '15:00', 'dinner_end', '22:00',
    'late_upload_window', '12 hours', 'edit_window', '48 hours', 'appeal_window', '72 hours', 'finalize_time', '09:00',
    'origin_whitelist', jsonb_build_array('com.apple.health', 'com.sec.android.app.shealth', 'android',
      'com.google.android.apps.healthdata', 'com.garmin.android.apps.connectmobile', 'com.fitbit.FitbitMobile',
      'com.huami.watch.hmwatchmanager', 'com.xiaomi.wearable')))
$$;

update challenge_rules r set skip_per_day = 2
  from challenges c where c.id = r.challenge_id and c.kind = 'monthly' and c.status in ('recruiting', 'checking', 'running');
