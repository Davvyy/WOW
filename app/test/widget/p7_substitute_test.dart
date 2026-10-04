// P7 의 빈·분석 대기 칸 안내는 서버가 실제로 쓴 대체값을 보여 준다(D61).
// 지난 날 = 그 날짜 장부 행의 substitute_values, 오늘 = 오늘 엔진 결과(어제 같은 칸이 더 크면 그 값).
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
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 지난 날(D+7 = 10.12)
const _past = '2026-10-12';

/// 서버 모드: 10.12 점심은 분석이 음식을 찾지 못한 끼니, 장부 행의 breakdown 은 [breakdown]
class _PastApi extends MockChalloryApi {
  _PastApi(this.breakdown);
  final Map<String, dynamic> breakdown;

  @override
  bool get isRemote => true;

  @override
  Future<List<ServerMeal>> fetchMealsOn(String localDate) async => localDate != _past
      ? const []
      : [ServerMeal(id: 'l-1', status: MealStatus.failed, version: 1, slot: MealSlot.lunch, capturedAt: DateTime.utc(2026, 10, 12, 3, 30))];

  @override
  Future<List<LedgerRow>> fetchLedger() async => [
        ledgerRowFromServer({
          'id': 'ds-7',
          'local_date': _past,
          'bmr': 1650,
          'a_d': 300,
          'i_d': 2385,
          'f_p': 1200,
          'd_d': 400,
          's_d': 30,
          'is_counted': true,
          'is_final': false,
          'breakdown': breakdown,
        }, mockChallenge.start),
      ];
}

/// 모의 모드: 어제 장부 행에 점심 [lunchKcal] 확정 기록
class _YesterdayApi extends MockChalloryApi {
  _YesterdayApi(this.lunchKcal);
  final double lunchKcal;

  @override
  Future<List<LedgerRow>> fetchLedger() async => [
        LedgerRow(
          d: curChallenge.dayIndex - 1,
          date: '',
          steps: 0,
          bmr: 0,
          a: 0,
          i: 0,
          dd: 0,
          s: 0,
          f: 0,
          floorApplied: false,
          substituted: const [],
          check: false,
          provisional: false,
          note: '',
          history: '',
          health: false,
          meals: [MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: lunchKcal)],
        ),
      ];
}

Future<void> _pumpPast(WidgetTester tester, Map<String, dynamic> breakdown) async {
  addTearDown(resetSession);
  await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'l-1', search: true, date: _past), overrides: [
    apiProvider.overrideWithValue(_PastApi(breakdown)),
    authServiceProvider.overrideWithValue(MockAuthService(true)),
  ]);
}

void main() {
  testWidgets('지난 날: 그 날짜 장부 행의 칸 대체값(전날 점심 900)을 보여 준다', (tester) async {
    await _pumpPast(tester, const {
      'intake': {
        'pending_slots': ['lunch'],
        'substitute_values': {'lunch': 900},
      },
    });
    expect(find.textContaining('확정하기 전까지는 900 kcal로 잠정 계산돼요'), findsOneWidget);
  });

  testWidgets('지난 날: 장부 행에 그 칸 대체값이 없으면 M_p', (tester) async {
    await _pumpPast(tester, const <String, dynamic>{});
    expect(find.textContaining('확정하기 전까지는 ${fmtM(meM)} kcal로 잠정 계산돼요'), findsOneWidget);
    expect(find.textContaining('900 kcal'), findsNothing);
  });

  testWidgets('오늘: 오늘 엔진 결과의 칸 대체값(어제 점심 900)을 보여 준다', (tester) async {
    addTearDown(resetSession);
    final c = await pumpApp(tester, location: R.meal(MealSlot.lunch, search: true), overrides: [
      apiProvider.overrideWithValue(_YesterdayApi(900)),
      mealsProvider.overrideWith(() => MealsNotifier(const [])),
    ]);
    expect(c.read(todayResultProvider).intake.substituteFor(MealSlot.lunch), 900);
    expect(meM, lessThan(900));
    expect(find.textContaining('확정하기 전까지는 900 kcal로 잠정 계산돼요'), findsOneWidget);
  });
}
