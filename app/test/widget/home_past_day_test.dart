// 지난 날 홈(전수 점검 #17 #18 #19 #21):
// 링 안내는 그날 끼니로 판단 · 앱바는 늘 오늘 진행(D+오늘/일수) · 날짜 칩은 실제 날짜 계산과 확정 여부 · 요일은 실제 연도.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/core/format.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/screens/p5_home.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 지난 날(D+7 = 10.12)
const _past = '2026-10-12';

ServerMealItem _item(String name, double kcal) => ServerMealItem(
    candidates: [name], candidateKcal: [kcal], candidateFoodCodes: const [null], count: 1, portionMultiplier: 1,
    hasBroth: false, needsCheck: false, aiKcal: kcal);

/// 서버 모드: 10.12 점심·저녁 확정, D = −116 → 0점(폰에서 본 10.19 와 같은 모양)
class _Api extends MockChalloryApi {
  _Api({this.isFinal = true, this.mainMealCount = 2});
  final bool isFinal;
  final int? mainMealCount;

  @override
  bool get isRemote => true;

  @override
  Future<List<ServerMeal>> fetchMealsOn(String localDate) async => localDate != _past
      ? const []
      : [
          ServerMeal(id: 'l-1', status: MealStatus.confirmed, version: 2, confirmedKcal: 900, slot: MealSlot.lunch,
              capturedAt: DateTime.utc(2026, 10, 12, 3, 30), items: [_item('제육덮밥', 900)]),
          ServerMeal(id: 'd-1', status: MealStatus.confirmed, version: 2, confirmedKcal: 1500, slot: MealSlot.dinner,
              capturedAt: DateTime.utc(2026, 10, 12, 10, 30), items: [_item('삼겹살', 1500)]),
        ];

  @override
  Future<List<LedgerRow>> fetchLedger() async => [
        ledgerRowFromServer({
          'id': 'ds-7',
          'local_date': _past,
          'bmr': 1650,
          'a_d': 300,
          'i_d': 2066,
          'f_p': 1200,
          'd_d': -116,
          's_d': 0,
          'is_counted': true,
          'is_final': isFinal,
          'finalized_at': isFinal ? '2026-10-13T00:00:05Z' : null,
          'breakdown': {
            'inputs': {
              'meals': [
                {'slot': 'lunch', 'status': 'confirmed', 'kcal': 900},
                {'slot': 'dinner', 'status': 'confirmed', 'kcal': 1500},
              ],
            },
            'intake': {'main_meal_count': ?mainMealCount, 'substitute_slots': ['breakfast']},
          },
        }, mockChallenge.start),
      ];
}

Future<ProviderContainer> _pickPast(WidgetTester tester, _Api api) async {
  addTearDown(resetSession);
  final c = await pumpApp(tester, overrides: [apiProvider.overrideWithValue(api), authServiceProvider.overrideWithValue(MockAuthService(true))]);
  c.read(selectedDayProvider.notifier).set(7);
  await tester.pumpAndSettle();
  return c;
}

void main() {
  group('#17 지난 날 링: 그날 확정한 끼니로 판단', () {
    testWidgets('점심·저녁 확정, D −116 → "끼니를 1개 이상" 대신 목표 초과 0점', (tester) async {
      await _pickPast(tester, _Api());
      expect(find.text('10.12 기록'), findsOneWidget);
      expect(find.textContaining('끼니를 1개 이상'), findsNothing);
      expect(find.text('목표보다 섭취가 많아요 · 0점'), findsOneWidget);
      expect(find.textContaining('+116'), findsWidgets);
    });

    testWidgets('장부에 끼니 수가 없어도(옛 행) 그날 끼니 목록으로 판단', (tester) async {
      await _pickPast(tester, _Api(mainMealCount: null));
      expect(find.textContaining('끼니를 1개 이상'), findsNothing);
      expect(find.text('목표보다 섭취가 많아요 · 0점'), findsOneWidget);
    });

    test('resultFromLedgerRow: 끼니 수는 breakdown 값, 없으면 그날 끼니 입력으로', () {
      LedgerRow row(Map<String, dynamic> intake) => ledgerRowFromServer({
            'local_date': _past, 'bmr': 1650, 'a_d': 0, 'i_d': 900, 'f_p': 1200, 'd_d': 0, 's_d': 0, 'is_counted': true, 'is_final': true,
            'breakdown': {
              'inputs': {'meals': [{'slot': 'lunch', 'status': 'confirmed', 'kcal': 900}]},
              'intake': intake,
            },
          }, mockChallenge.start);
      expect(resultFromLedgerRow(row({'main_meal_count': 3})).intake.mainMealCount, 3);
      expect(resultFromLedgerRow(row({})).intake.mainMealCount, 1);
    });
  });

  testWidgets('#18 앱바는 고른 날과 상관없이 오늘 진행(D+8/28), 고른 날은 날짜 띠·머리글에', (tester) async {
    await _pickPast(tester, _Api());
    expect(find.text('D+8/28'), findsOneWidget);
    expect(find.text('D+7/28'), findsNothing);
    expect(find.text('10.12 기록'), findsOneWidget);
  });

  group('#19 지난 날 칩', () {
    testWidgets('확정된 날: "확정 · 다음 날 09:00"', (tester) async {
      await _pickPast(tester, _Api(isFinal: true));
      expect(find.text('확정 · 10.13 09:00'), findsOneWidget);
    });

    testWidgets('아직 확정 전(잠정): "확정 예정 · 다음 날 09:00"', (tester) async {
      await _pickPast(tester, _Api(isFinal: false));
      expect(find.text('확정 예정 · 10.13 09:00'), findsOneWidget);
      expect(find.text('확정 · 10.13 09:00'), findsNothing);
    });

    test('월말은 다음 달 1일로', () {
      expect(pastDayChipText(DateTime(2026, 10, 31), isFinal: true, finalizeTime: '09:00'), '확정 · 11.1 09:00');
      expect(pastDayChipText(DateTime(2026, 12, 31), isFinal: false, finalizeTime: '09:30'), '확정 예정 · 1.1 09:30');
      expect(pastDayChipText(DateTime(2027, 2, 28), isFinal: true, finalizeTime: '09:00'), '확정 · 3.1 09:00');
    });
  });

  test('#21 요일은 실제 연도로', () {
    expect(weekdayKo(DateTime(2026, 10, 25)), '일');
    expect(weekdayKo(DateTime(2027, 1, 1)), '금');
    expect(weekdayKo(DateTime(2028, 2, 29)), '화');
  });
}
