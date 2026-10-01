// 서버 RPC score_simulate_from_inputs 와 같은 JSON 형식의 입·출력 변환.
// 골든 테스트와 P11 시뮬레이터(서버 호출이 안 될 때 로컬 계산)에서 함께 쓴다.
import 'engine.dart';

MealSlot _slot(String s) => MealSlot.values.byName(s);

MealStatus _status(String s) => s == 'void' ? MealStatus.voided : MealStatus.values.byName(s);

SessionType _type(String s) => switch (s) {
      'running' => SessionType.running,
      'stair' => SessionType.stair,
      _ => SessionType.walking,
    };

SimulateInput simulateInputFromJson(Map<String, dynamic> j) {
  final hasProfile = j['sex'] != null;
  return SimulateInput(
    profile: hasProfile
        ? Profile(
            sex: j['sex'] == 'M' ? Sex.m : Sex.f,
            weightKg: (j['weight_kg'] as num).toDouble(),
            heightCm: (j['height_cm'] as num).toDouble(),
            age: (j['age'] as num).toInt(),
          )
        : null,
    bmr: hasProfile ? null : (j['bmr'] as num).toInt(),
    weightKg: hasProfile ? null : (j['weight_kg'] as num).toDouble(),
    stepsTotal: (j['steps_total'] as num?)?.toInt() ?? 0,
    floors: (j['floors'] as num?)?.toInt() ?? 0,
    skipsUsedThisWeek: (j['skips_used_this_week'] as num?)?.toInt() ?? 0,
    sessions: [
      for (final s in (j['sessions'] as List? ?? const []).cast<Map<String, dynamic>>())
        SessionInput(
          type: _type(s['type'] as String),
          minutes: (s['minutes'] as num).toDouble(),
          distanceM: (s['distance_m'] as num?)?.toDouble(),
          stepsInRange: (s['steps_in_range'] as num?)?.toInt() ?? 0,
          met: (s['met'] as num?)?.toDouble(),
          isCounted: s['is_counted'] as bool? ?? true,
          manual: s['recording_method'] == 'MANUAL_ENTRY',
        ),
    ],
    meals: [
      for (final m in (j['meals'] as List? ?? const []).cast<Map<String, dynamic>>())
        MealInput(
          slot: _slot(m['slot'] as String),
          status: _status(m['status'] as String),
          kcal: (m['kcal'] as num?)?.toDouble() ?? 0,
          aiKcal: (m['ai_kcal'] as num?)?.toDouble(),
        ),
    ],
  );
}

/// SQL 출력과 같은 평면 키(비교용). 서버 응답은 activity/intake 중첩이므로 [flattenSqlResult] 참고.
Map<String, dynamic> simulateToJson(SimulateResult r) => {
      'bmr': r.bmr,
      'm_p': r.intake.mP,
      'f_p': r.score.fP,
      'steps_out': r.activity.stepsOut,
      'steps_net_kcal': r.activity.stepsNetKcal,
      'sessions_net_kcal': r.activity.sessionsNetKcal,
      'floors_kcal': r.activity.floorsKcal,
      'a_raw': r.activity.aRaw,
      'a_d': r.activity.aD,
      'a_capped': r.activity.aCapped,
      'i_d': r.intake.iD,
      'd_d': r.score.dD,
      's_d': r.score.sD,
      'main_meal_count': r.intake.mainMealCount,
      'snack_count': r.intake.snackCount,
      'floor_applied': r.score.floorApplied,
      'skip_over': r.intake.skipOver,
    };

/// 서버 RPC 응답(중첩) → 평면 키.
Map<String, dynamic> flattenSqlResult(Map<String, dynamic> j) => {
      'bmr': j['bmr'],
      'm_p': j['m_p'],
      'f_p': j['f_p'],
      ...(j['activity'] as Map<String, dynamic>),
      ...(j['intake'] as Map<String, dynamic>),
      'd_d': j['d_d'],
      's_d': j['s_d'],
      'floor_applied': j['floor_applied'],
    };
