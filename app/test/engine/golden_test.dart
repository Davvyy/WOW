// 골든 회귀: supabase/tests/golden_cases.json 의 같은 입력으로 Dart 엔진을 검증하고,
// supabase/tests/golden_sql_results.json(서버 SQL 함수 실행 결과, `supabase/tests/run.sh`가 갱신)
// 과 필드별로 비교한다. 허용 오차 ±0.05 (04 §9).
import 'dart:convert';
import 'dart:io';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/core/engine/json_input.dart';
import 'package:flutter_test/flutter_test.dart';

const tol = 0.05;

Map<String, dynamic> _load(String rel) {
  final f = File(rel);
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final cases = (_load('../supabase/tests/golden_cases.json')['cases'] as List).cast<Map<String, dynamic>>();
  const engine = ChalloryEngine();

  group('골든 케이스 (docs/04 §6·§9)', () {
    for (final c in cases) {
      test('${c['id']} ${c['desc']}', () {
        final out = simulateToJson(engine.simulate(simulateInputFromJson(c['input'] as Map<String, dynamic>)));
        final expect_ = c['expect'] as Map<String, dynamic>;
        for (final e in expect_.entries) {
          final actual = out[e.key];
          if (e.value is num) {
            expect((actual as num).toDouble(), closeTo((e.value as num).toDouble(), tol), reason: '${c['id']}.${e.key}');
          } else {
            expect(actual, e.value, reason: '${c['id']}.${e.key}');
          }
        }
      });
    }
  });

  group('서버 SQL 결과와 비교', () {
    final f = File('../supabase/tests/golden_sql_results.json');
    test('golden_sql_results.json 존재', () => expect(f.existsSync(), isTrue, reason: 'supabase/tests/run.sh 로 생성'));
    if (!f.existsSync()) return;
    final sql = (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)['results'] as Map<String, dynamic>;
    const keys = ['bmr', 'm_p', 'f_p', 'steps_out', 'steps_net_kcal', 'sessions_net_kcal', 'floors_kcal', 'a_raw', 'a_d', 'a_capped', 'i_d', 'd_d', 's_d', 'main_meal_count', 'snack_count', 'floor_applied', 'skip_over'];
    for (final c in cases) {
      test('${c['id']} Dart == SQL', () {
        final s = sql[c['id']] as Map<String, dynamic>?;
        expect(s, isNotNull, reason: 'SQL 결과에 ${c['id']} 없음');
        final d = simulateToJson(engine.simulate(simulateInputFromJson(c['input'] as Map<String, dynamic>)));
        for (final k in keys) {
          final dv = d[k];
          final sv = s![k];
          if (dv is num || sv is num) {
            expect((dv as num).toDouble(), closeTo((sv as num).toDouble(), 1e-9), reason: '${c['id']}.$k dart=$dv sql=$sv');
          } else {
            expect(dv, sv, reason: '${c['id']}.$k');
          }
        }
      });
    }
  });

  group('단위 규칙', () {
    test('T01 BMR round10 half-up', () {
      expect(ChalloryEngine.bmr(const Profile(sex: Sex.m, weightKg: 70, heightCm: 175, age: 30)).bmr, 1650);
      expect(ChalloryEngine.bmr(const Profile(sex: Sex.f, weightKg: 58, heightCm: 163, age: 30)).bmr, 1290);
      expect(round10(1645.0), 1650);
      expect(round10(1644.9), 1640);
    });
    test('round1 은 +∞ 방향 half-up (JS Math.round 와 동일)', () {
      expect(round1(28.85), closeTo(28.9, 1e-9));
      expect(round1(-603.45), closeTo(-603.4, 1e-9));
    });
    test('T07 층수 72층 75 kg → 105.7, 없음 → 0', () {
      final a = engine.activity(weightKg: 75, floors: 72);
      expect(a.floorsKcal, closeTo(105.7, tol));
      expect(engine.activity(weightKg: 75).floorsKcal, 0);
    });
    test('T11 자동 확정값', () {
      expect(engine.autoConfirmValue(1650, 850), closeTo(1105, 1e-9));
      expect(engine.autoConfirmValue(1650, 400), closeTo(742.5, 1e-9));
    });
  });
}
