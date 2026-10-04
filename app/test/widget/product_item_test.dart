// P7 가공식품(상품, D63) 항목: 고른 후보가 상품이면 단위 라벨·'회분'/'개' 스테퍼, 음식 후보로 바꾸면 1인분으로 돌아간다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 서버 초안: AI 가 포장 상품 칙촉 1회분으로 매칭, 두 번째 후보는 음식 초코칩쿠키
final _draft = ServerMeal(
  id: 'm-chic',
  status: MealStatus.draft,
  version: 1,
  aiKcal: 150.3,
  slot: MealSlot.lunch,
  capturedAt: DateTime.utc(2026, 10, 13, 3, 10),
  items: const [
    ServerMealItem(candidates: ['칙촉', '초코칩쿠키'], candidateKcal: [150.3, 308], candidateFoodCodes: ['P101-103000100-5334', 'D000070'],
        count: 1, portionMultiplier: 1, hasBroth: false, needsCheck: false, aiKcal: 150.3, unitLabel: '1회분(30g)'),
  ],
);

void main() {
  testWidgets('상품 후보는 단위 라벨·회분 스테퍼, 음식 후보로 바꾸면 1인분(라벨 없음)', (tester) async {
    await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'm-chic'), overrides: [
      apiProvider.overrideWithValue(MockChalloryApi()),
      mealsProvider.overrideWith(() => MealsNotifier([
            for (final m in buildTodayMeals()) if (m.slot != MealSlot.lunch) m,
            ...mealRecordsFromServer([_draft]),
          ])),
    ]);
    expect(find.text('가정 분량 · 1회분(30g)'), findsOneWidget);
    expect(find.text('1.0회분'), findsOneWidget);

    await tester.tap(find.text('초코칩쿠키'));
    await tester.pumpAndSettle();
    expect(find.textContaining('회분(30g)'), findsNothing);
    expect(find.text('1.0인분'), findsOneWidget);
  });
}
