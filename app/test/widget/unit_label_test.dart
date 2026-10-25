// 먹은 양 단위(전수 점검 #26): 공기는 밥 한 그릇일 때만. 초밥·김밥·주먹밥은 이름이 '밥'으로 끝나도 인분.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/meal_wire.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

ServerMealItem _item(String name, {double mult = 1, int count = 1}) => ServerMealItem(
    candidates: [name], candidateKcal: const [400], candidateFoodCodes: const [null], count: count, portionMultiplier: mult,
    hasBroth: false, needsCheck: false, aiKcal: 400 * mult * count);

void main() {
  test('isRiceBowlName: 밥 한 그릇만', () {
    for (final n in ['흰쌀밥', '현미밥', '잡곡밥', '볶음밥', '비빔밥', '제육덮밥']) {
      expect(isRiceBowlName(n), isTrue, reason: n);
    }
    for (final n in ['모둠초밥', '유부초밥', '연어초밥', '김밥', '참치김밥', '주먹밥', '초밥_광어', '김치찌개', '밥버거']) {
      expect(isRiceBowlName(n), isFalse, reason: n);
    }
  });

  test('서버 항목: 모둠초밥은 인분(side), 흰쌀밥은 공기(rice) · kcal 은 그대로', () {
    final sushi = mealItemFromServer(_item('모둠초밥', mult: 1.2), 0);
    expect([sushi.kind, sushi.portion, sushi.mult], [ItemKind.side, '1인분', 1.2]);
    expect(sushi.rawKcal, closeTo(480, 0.01));
    final rice = mealItemFromServer(_item('흰쌀밥', mult: 1.5), 0);
    expect([rice.kind, rice.portion], [ItemKind.rice, '1공기']);
    // 개수 2 이상 초밥은 개수 항목(접어서 공기로 만들지 않는다)
    final two = mealItemFromServer(_item('김밥', count: 2), 0);
    expect([two.kind, two.count], [ItemKind.count, 2]);
    expect(two.rawKcal, closeTo(800, 0.01));
  });

  testWidgets('P7: 모둠초밥 1.2 → "1.2인분", 공기 없음', (tester) async {
    await pumpApp(tester, location: R.meal(MealSlot.dinner, meal: 'm-s'), overrides: [
      apiProvider.overrideWithValue(MockChalloryApi()),
      mealsProvider.overrideWith(() => MealsNotifier([
            for (final m in buildTodayMeals()) if (m.slot != MealSlot.dinner) m,
            ...mealRecordsFromServer([
              ServerMeal(id: 'm-s', status: MealStatus.draft, version: 1, aiKcal: round1(480), slot: MealSlot.dinner,
                  capturedAt: DateTime.utc(2026, 10, 25, 10, 10), items: [_item('모둠초밥', mult: 1.2)]),
            ]),
          ])),
    ]);
    expect(find.textContaining('가정 분량 · 1.2인분'), findsOneWidget);
    expect(find.text('1.2인분'), findsOneWidget, reason: '먹은 양 스테퍼');
    expect(find.textContaining('공기'), findsNothing);
  });
}
