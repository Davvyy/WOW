// P7 개수 항목: 개수 스테퍼 아래 '1개 크기' 배수 스테퍼(0.1~3.0, ½·1·1.5·2). kcal = 1개 kcal × 개수 × 배수.
// AI 가 개수와 함께 1개 크기(servings)를 예측한 초안은 열었을 때 합계가 AI 초안 kcal 과 같다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

class _ConfirmSpy extends MockChalloryApi {
  List<Map<String, dynamic>>? sent;
  @override
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey}) async {
    sent = items;
    return ConfirmResult(mealId: mealId, confirmedKcal: wireTotal(items), version: version + 1);
  }
}

/// 서버 초안: 삶은 달걀 2개 × 1.2배(1개 78 kcal) → ai_kcal 187.2
final _eggDraft = ServerMeal(
  id: 'm-egg',
  status: MealStatus.draft,
  version: 1,
  aiKcal: 187.2,
  slot: MealSlot.lunch,
  capturedAt: DateTime.utc(2026, 10, 13, 3, 10),
  items: const [
    ServerMealItem(candidates: ['삶은 달걀', '계란후라이'], candidateKcal: [78, 95], candidateFoodCodes: [null, null], count: 2,
        portionMultiplier: 1.2, hasBroth: false, needsCheck: false, aiKcal: 187.2),
  ],
);

Future<_ConfirmSpy> _open(WidgetTester tester) async {
  final api = _ConfirmSpy();
  await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'm-egg'), overrides: [
    apiProvider.overrideWithValue(api),
    mealsProvider.overrideWith(() => MealsNotifier([
          for (final m in buildTodayMeals()) if (m.slot != MealSlot.lunch) m,
          ...mealRecordsFromServer([_eggDraft]),
        ])),
  ]);
  return api;
}

Finder _cta(String prefix) => find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith(prefix));

void main() {
  testWidgets('AI 초안(달걀 2개 × 1.2배)을 열면 합계 = AI 초안 187 kcal', (tester) async {
    await _open(tester);
    expect(find.textContaining('AI 초안 약 187'), findsOneWidget);
    expect(_cta('확정 · 약 187 kcal'), findsOneWidget);
    expect(find.text('1.2배'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('계란후라이 228 kcal')), findsOneWidget, reason: '후보 칩도 95 × 2 × 1.2');
  });

  testWidgets("개수 스테퍼 아래 '1개 크기' 스테퍼: + → 1.3배, '1' 칩 → 1.0배, 확정은 count 2 · portion_multiplier 1.0", (tester) async {
    final api = await _open(tester);
    expect(find.byTooltip('하나 더하기'), findsOneWidget, reason: '개 스테퍼는 그대로');
    expect(find.text('1개 크기'), findsOneWidget);
    final countY = tester.getCenter(find.byTooltip('하나 더하기')).dy;
    expect(tester.getCenter(find.text('1개 크기')).dy, greaterThan(countY), reason: '개수 스테퍼 아래');

    await tester.tap(find.byTooltip('1개 크기 늘리기'));
    await tester.pumpAndSettle();
    expect(find.text('1.3배'), findsOneWidget);
    expect(_cta('확정 · 약 203 kcal'), findsOneWidget, reason: '78 × 2 × 1.3 = 202.8');

    await tester.tap(find.descendant(of: find.byType(ChSeg<int>), matching: find.text('1')));
    await tester.pumpAndSettle();
    expect(find.text('1.0배'), findsOneWidget);
    expect(_cta('확정 · 약 156 kcal'), findsOneWidget);

    await tester.tap(find.byTooltip('하나 더하기'));
    await tester.pumpAndSettle();
    expect(_cta('확정 · 약 234 kcal'), findsOneWidget, reason: '78 × 3 × 1.0');
    await tester.tap(find.byTooltip('하나 빼기'));
    await tester.pumpAndSettle();

    await tester.tap(_cta('확정'));
    await tester.pumpAndSettle();
    expect(api.sent!.single['count'], 2);
    expect(api.sent!.single['portion_multiplier'], 1.0);
  });

  testWidgets("'1개 크기'는 0.1~3.0 에서 멈춘다", (tester) async {
    await _open(tester);
    await tester.tap(find.descendant(of: find.byType(ChSeg<int>), matching: find.text('½')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byTooltip('1개 크기 줄이기'), warnIfMissed: false);
      await tester.pumpAndSettle();
    }
    expect(find.text('0.1배'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ChSeg<int>), matching: find.text('2')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 11; i++) {
      await tester.tap(find.byTooltip('1개 크기 늘리기'), warnIfMissed: false);
      await tester.pumpAndSettle();
    }
    expect(find.text('3.0배'), findsOneWidget);
    expect(_cta('확정 · 약 468 kcal'), findsOneWidget, reason: '78 × 2 × 3.0');
  });
}
