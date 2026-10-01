import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/engine/engine.dart';

/// P11 시뮬레이터가 쓰는 점수 계산 추상화.
/// 로컬 구현은 앱에 포팅된 엔진, 원격 구현은 서버 RPC `score_simulate_from_inputs`(05 API #16).
/// 순위에 들어가는 값은 항상 서버가 계산하며, 이 인터페이스는 화면 미리보기용이다.
abstract class ScoreSimulator {
  Future<SimulateResult> simulate(SimulateInput input);
}

class LocalScoreSimulator implements ScoreSimulator {
  const LocalScoreSimulator([this.engine = const ChalloryEngine()]);
  final ChalloryEngine engine;

  @override
  Future<SimulateResult> simulate(SimulateInput input) async => engine.simulate(input);
}

/// Supabase RPC 구현. 호출이 끝내 안 되면(오프라인 등) [fallback] 으로 로컬 계산한다.
class SupabaseScoreSimulator implements ScoreSimulator {
  SupabaseScoreSimulator(this._client, {this.fallback = const LocalScoreSimulator()});

  final SupabaseClient _client;
  final ScoreSimulator fallback;

  @override
  Future<SimulateResult> simulate(SimulateInput input) async {
    try {
      final res = await _client.rpc('score_simulate_from_inputs', params: {'p': simulateInputToJson(input)});
      return simulateResultFromRpc(Map<String, dynamic>.from(res as Map));
    } catch (_) {
      return fallback.simulate(input);
    }
  }
}

String _statusWire(MealStatus s) => s == MealStatus.voided ? 'void' : s.name;

String _typeWire(SessionType t) => t.name;

/// json_input.dart 의 [simulateInputFromJson] 과 역방향. 서버 RPC 입력 형식(`p`)이다.
Map<String, dynamic> simulateInputToJson(SimulateInput i) => {
      if (i.profile != null) ...{
        'sex': i.profile!.sex == Sex.m ? 'M' : 'F',
        'weight_kg': i.profile!.weightKg,
        'height_cm': i.profile!.heightCm,
        'age': i.profile!.age,
      } else ...{
        'bmr': i.bmr,
        'weight_kg': i.weightKg,
      },
      'steps_total': i.stepsTotal,
      'floors': i.floors,
      'skips_used_this_week': i.skipsUsedThisWeek,
      'sessions': [
        for (final s in i.sessions)
          {
            'type': _typeWire(s.type),
            'minutes': s.minutes,
            if (s.distanceM != null) 'distance_m': s.distanceM,
            'steps_in_range': s.stepsInRange,
            if (s.met != null) 'met': s.met,
            'is_counted': s.isCounted,
            if (s.manual) 'recording_method': 'MANUAL_ENTRY',
          },
      ],
      'meals': [
        for (final m in i.meals)
          {
            'slot': m.slot.name,
            'status': _statusWire(m.status),
            'kcal': m.kcal,
            if (m.aiKcal != null) 'ai_kcal': m.aiKcal,
          },
      ],
    };

double _d(Object? v, [double fallback = 0]) => (v as num?)?.toDouble() ?? fallback;
int _i(Object? v) => (v as num?)?.toInt() ?? 0;

List<MealSlot> _slots(Object? v) => [
      for (final s in (v as List? ?? const [])) MealSlot.values.byName(s as String),
    ];

/// 서버 RPC 응답(중첩 JSON) → [SimulateResult].
SimulateResult simulateResultFromRpc(Map<String, dynamic> j) {
  final a = Map<String, dynamic>.from(j['activity'] as Map);
  final n = Map<String, dynamic>.from(j['intake'] as Map);
  return SimulateResult(
    bmr: _i(j['bmr']),
    bmrRaw: (j['bmr_raw'] as num?)?.toDouble(),
    activity: ActivityResult(
      stepsOut: _i(a['steps_out']),
      stepsNetKcal: _d(a['steps_net_kcal']),
      sessionsNetKcal: _d(a['sessions_net_kcal']),
      floorsKcal: _d(a['floors_kcal']),
      aRaw: _d(a['a_raw']),
      aD: _d(a['a_d']),
      aCapped: a['a_capped'] as bool? ?? false,
      sessionMets: [for (final m in (a['session_mets'] as List? ?? const [])) (m as num).toDouble()],
    ),
    intake: IntakeResult(
      iD: _d(n['i_d']),
      mP: _d(n['m_p']),
      mainMealCount: _i(n['main_meal_count']),
      snackCount: _i(n['snack_count']),
      substituteSlots: _slots(n['substitute_slots']),
      draftSlots: [
        for (final d in (n['draft_slots'] as List? ?? const []))
          DraftSlot(MealSlot.values.byName((d as Map)['slot'] as String), _d(d['value'])),
      ],
      pendingSlots: _slots(n['pending_slots']),
      skipsToday: _i(n['skips_today']),
      skipOver: n['skip_over'] as bool? ?? false,
    ),
    score: ScoreResult(
      fP: _d(j['f_p']),
      floorApplied: j['floor_applied'] as bool? ?? false,
      dD: _d(j['d_d']),
      sD: _d(j['s_d']),
      ratio: _d(j['ratio']),
    ),
  );
}
