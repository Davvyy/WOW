-- default_rules() 의 걸음 출처 허용 목록을 규칙 테이블의 컬럼 기본값과 다시 맞춘다.
-- 컬럼 기본값에는 휴대폰 센서 출처가 들어갔는데(20261004002200) 함수는 처음 목록을 그대로 복사해 왔다.
-- 간식 기준(snack_kcal)은 일부러 150 으로 둔다: 규칙 행이 없을 때의 값은 SQL·앱·콘솔 세 엔진이 함께 맞추는 골든 기준
-- (tests/golden_cases.json, T10a 가 150 미만 간식 판정을 고정)이고, 실제 챌린지는 규칙 행의 0 을 쓴다(D59).
-- 화면 미리보기는 챌린지 id 를 보내 그 챌린지 규칙으로 계산한다. 두 곳이 어긋나면 tests/49 가 잡는다.

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
      'com.huami.watch.hmwatchmanager', 'com.xiaomi.wearable', 'com.android.healthconnect.phone.')))
$$;
