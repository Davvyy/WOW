import 'package:challory/core/engine/engine.dart';
import 'package:challory/core/engine/json_input.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/services/health/health_models.dart';
import 'package:challory/services/health/health_source.dart';
import 'package:challory/services/health/mock_health_source.dart';
import 'package:challory/services/score_simulator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('건강 데이터 동기화 배치 (docs/05 §5)', () {
    test('KST D·D−1·D−2 윈도: UTC 15:30 은 이미 KST 다음 날', () {
      expect(kstWindowDates(DateTime.utc(2026, 10, 13, 15, 30)), ['2026-10-14', '2026-10-13', '2026-10-12']);
      expect(kstWindowDates(DateTime.utc(2026, 10, 13, 14, 59)), ['2026-10-13', '2026-10-12', '2026-10-11']);
    });

    test('배치 JSON 형식', () async {
      final days = await const MockHealthSource().fetchDays(now: DateTime.utc(2026, 10, 13, 12));
      expect(days, hasLength(3));
      final b = buildSyncBatch([
        HealthDay(
          localDate: '2026-10-01',
          stepsTotal: 9000,
          stepsManual: 0,
          floors: 12,
          platformActiveKcal: 310,
          sources: const [HealthOrigin(origin: 'com.sec.android.app.shealth', method: RecordMethod.automatic)],
          sessions: [
            HealthSession(
              platformUid: 'hc:abc',
              type: 'running',
              start: DateTime.utc(2026, 9, 30, 22),
              end: DateTime.utc(2026, 9, 30, 22, 30),
              distanceM: 4500,
              stepsInRange: 4500,
              origin: 'com.garmin.android.apps.connectmobile',
              method: RecordMethod.automatic,
            ),
          ],
        ),
      ], clientBatchId: 'fixed-id');
      expect(b['client_batch_id'], 'fixed-id');
      expect(b['tz'], 'Asia/Seoul');
      final d = (b['days'] as List).single as Map<String, dynamic>;
      expect(d.keys, containsAll(['local_date', 'steps_total', 'steps_manual', 'floors', 'platform_active_kcal', 'has_manual_source', 'sources', 'sessions']));
      expect(d.containsKey('kcal'), isFalse); // 앱은 kcal 환산 값을 보내지 않는다
      final s = (d['sessions'] as List).single as Map<String, dynamic>;
      expect(s['start'], '2026-10-01T07:00:00+09:00');
      expect(s['end'], '2026-10-01T07:30:00+09:00');
      expect(s['platform_uid'], 'hc:abc');
      expect((d['sources'] as List).single, {'origin': 'com.sec.android.app.shealth', 'method': 'AUTOMATICALLY_RECORDED'});
    });

    test('iPhone 모의: 기록 9,340 − 수동 340 = 검증 9,000, 활동 칼로리는 참고값', () async {
      final days = await const MockHealthSource(ios: true).fetchDays(now: DateTime.utc(2026, 10, 13, 12));
      expect(days.first.stepsTotal, 9340);
      expect(days.first.stepsManual, 340);
      expect(days.first.stepsVerified, 9000);
      expect(days.first.platformActiveKcal, 310);
    });

    test('uuid v4 형식', () {
      expect(newUuidV4(), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });
  });

  group('ScoreSimulator', () {
    test('로컬 구현은 엔진과 같은 값(28.8)', () async {
      final input = SimulateInput(profile: mockMe.profile, stepsTotal: 9000, meals: buildTodayMeals().map((m) => m.toInput()).toList());
      final r = await const LocalScoreSimulator().simulate(input);
      expect(r.score.sD, 28.8);
    });

    test('RPC 입력 JSON 은 json_input.dart 형식과 왕복된다', () {
      final input = SimulateInput(
        profile: mockMe.profile,
        stepsTotal: 12000,
        sessions: const [SessionInput(type: SessionType.running, minutes: 30, distanceM: 4500, stepsInRange: 4500)],
        meals: const [
          MealInput(slot: MealSlot.breakfast, status: MealStatus.confirmed, kcal: 400),
          MealInput(slot: MealSlot.lunch, status: MealStatus.draft, aiKcal: 850),
          MealInput(slot: MealSlot.dinner, status: MealStatus.voided),
        ],
        skipsUsedThisWeek: 1,
      );
      final json = simulateInputToJson(input);
      expect(json['sex'], 'M');
      expect((json['meals'] as List).last, containsPair('status', 'void'));
      final back = simulateInputFromJson(json);
      expect(engine.simulate(back).score.sD, engine.simulate(input).score.sD);
    });

    test('RPC 응답(중첩 JSON) 파싱', () {
      final local = engine.simulate(SimulateInput(profile: mockMe.profile, stepsTotal: 9000, meals: buildTodayMeals().map((m) => m.toInput()).toList()));
      final res = simulateResultFromRpc({
        'bmr': 1650,
        'bmr_raw': 1648.75,
        'm_p': 742.5,
        'f_p': 1320,
        'activity': {'steps_out': 9000, 'steps_net_kcal': 294.0, 'sessions_net_kcal': 0, 'floors_kcal': 0, 'a_raw': 294.0, 'a_d': 294.0, 'a_capped': false, 'session_mets': []},
        'intake': {'i_d': 1800.0, 'm_p': 742.5, 'main_meal_count': 3, 'snack_count': 0, 'substitute_slots': [], 'pending_slots': [], 'draft_slots': [], 'skips_today': 0, 'skip_over': false},
        'd_d': 144.0,
        's_d': 28.8,
        'ratio': 0.288,
        'floor_applied': false,
      });
      expect(res.score.sD, local.score.sD);
      expect(res.e, local.e);
      expect(res.intake.mainMealCount, 3);
    });
  });
}
