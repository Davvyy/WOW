// 수정 기한이 지난 지난 날 끼니(전수 점검 #23): '볼 수만 있어요'면 체크·후보 칩·검색·먹은 양 스테퍼가
// 눌리는 모양으로 보이지 않고, 눌러도 아무것도 바뀌지 않는다. 기한 안(정정 가능)이면 그대로 편집할 수 있다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

const _past = '2026-10-12';

class _Api extends MockChalloryApi {
  _Api(this.finalizedAt);
  final DateTime finalizedAt;

  @override
  bool get isRemote => true;

  @override
  Future<List<ServerMeal>> fetchMealsOn(String localDate) async => localDate != _past
      ? const []
      : [
          ServerMeal(id: 'l-1', status: MealStatus.confirmed, version: 2, confirmedKcal: 520, slot: MealSlot.lunch,
              capturedAt: DateTime.utc(2026, 10, 12, 3, 30), items: const [
                ServerMealItem(candidates: ['비빔밥', '돌솥비빔밥'], candidateKcal: [520, 600], candidateFoodCodes: [null, null], count: 1,
                    portionMultiplier: 1, hasBroth: false, needsCheck: false, aiKcal: 520),
              ]),
        ];

  @override
  Future<List<LedgerRow>> fetchLedger() async => [
        ledgerRowFromServer({
          'local_date': _past, 'bmr': 1650, 'a_d': 300, 'i_d': 1500, 'f_p': 1200, 'd_d': 400, 's_d': 30, 'is_counted': true,
          'is_final': true, 'finalized_at': finalizedAt.toUtc().toIso8601String(), 'breakdown': const <String, dynamic>{},
        }, mockChallenge.start),
      ];
}

Future<void> _open(WidgetTester tester, Duration sinceFinal) async {
  addTearDown(resetSession);
  await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'l-1', date: _past), overrides: [
    apiProvider.overrideWithValue(_Api(DateTime.now().subtract(sinceFinal))),
    authServiceProvider.overrideWithValue(MockAuthService(true)),
  ]);
}

void main() {
  testWidgets('기한 지남: 편집 도구가 없고 체크는 꺼진 모양, 눌러도 합계 그대로', (tester) async {
    await _open(tester, const Duration(hours: 49));
    expect(find.text('수정 기한(확정 후 48시간)이 지나 볼 수만 있어요'), findsOneWidget);
    expect(find.text('비빔밥'), findsWidgets);
    expect(find.textContaining('가정 분량 · 1공기'), findsOneWidget, reason: '먹은 양은 글로 보인다');
    expect(find.text('검색'), findsNothing, reason: '후보 검색 칩 없음');
    expect(find.text('돌솥비빔밥'), findsNothing, reason: '다른 후보 칩 없음');
    expect(find.byTooltip('더 먹음'), findsNothing, reason: '먹은 양 스테퍼 없음');
    expect(find.text('먹은 양 · 0.1공기 단위'), findsNothing);
    final check = tester.widget<ChCheck>(find.byType(ChCheck));
    expect(check.onChanged, isNull, reason: '체크는 바꿀 수 없다');
    await tester.tap(find.byType(ChCheck), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.textContaining('약 520'), findsWidgets);
    expect(find.textContaining('먹지 않음'), findsNothing);
  });

  testWidgets('기한 안(확정 뒤 47시간): 체크·후보·스테퍼가 그대로 있다', (tester) async {
    await _open(tester, const Duration(hours: 47));
    expect(find.text('검색'), findsOneWidget);
    expect(find.text('돌솥비빔밥'), findsOneWidget);
    expect(find.byTooltip('더 먹음'), findsOneWidget);
    expect(tester.widget<ChCheck>(find.byType(ChCheck)).onChanged, isNotNull);
  });
}
