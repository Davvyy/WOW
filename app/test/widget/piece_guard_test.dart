// 조각 수 가드(D73): 서버가 조각 수를 그릇 수로 낸 것으로 보고 인분으로 바꾼 항목(ai_piece_guard)은 그 카드에 안내 배너를,
// 1,500 kcal 넘는 항목은 조용한 확인 한 줄을 띄운다(확정 버튼은 그대로 켜져 있다).
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/meal_wire.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

const _guardBold = '조각 수로 보여 양을 인분으로 바꿨어요.';
const _guardRest = ' 실제로 먹은 양이 맞는지 확인해 주세요.';
const _bigLine = '한 항목이 1,500 kcal 넘어요 · 양을 확인해 주세요';

/// 모둠초밥 12점이 1인분(453) × 11 로 왔던 항목을 서버가 1.1인분으로 바꾼 초안
const _sushi = ServerMealItem(
    candidates: ['초밥_광어', '모둠초밥'], candidateKcal: [453, 453], candidateFoodCodes: ['D000700', null], count: 1, portionMultiplier: 1.1,
    hasBroth: false, needsCheck: true, aiKcal: 498.3, aiPieceGuard: true);

/// 갈비찜 2접시(900 × 2) — 가드 대상이 아닌 큰 항목
const _ribs = ServerMealItem(
    candidates: ['갈비찜'], candidateKcal: [900], candidateFoodCodes: ['D000720'], count: 2, portionMultiplier: 1, hasBroth: false,
    needsCheck: false, aiKcal: 1800);

Future<void> _open(WidgetTester tester, List<ServerMealItem> items) async {
  await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'm-g'), overrides: [
    apiProvider.overrideWithValue(MockChalloryApi()),
    mealsProvider.overrideWith(() => MealsNotifier([
          for (final m in buildTodayMeals()) if (m.slot != MealSlot.lunch) m,
          ...mealRecordsFromServer([
            ServerMeal(
              id: 'm-g',
              status: MealStatus.draft,
              version: 1,
              aiKcal: round1(items.fold<double>(0, (a, i) => a + i.aiKcal)),
              slot: MealSlot.lunch,
              capturedAt: DateTime.utc(2026, 10, 25, 3, 10),
              items: items,
            ),
          ]),
        ])),
  ]);
}

Finder _cta(String prefix) => find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith(prefix));
Finder _banner() => find.textContaining(_guardBold, findRichText: true);

void main() {
  test('서버 항목: ai_piece_guard 를 읽고(없으면 false), 편집 항목까지 유지한다', () {
    Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) => {
          'chosen_name': '초밥_광어', 'name_candidates': ['초밥_광어'], 'candidate_kcal': [453], 'candidate_food_codes': ['D000700'], 'count': 1,
          'portion_multiplier': 1.1, 'ai_kcal': 498.3, ...extra,
        };
    expect(ServerMealItem.fromJson(row({'ai_piece_guard': true})).aiPieceGuard, isTrue);
    expect(ServerMealItem.fromJson(row()).aiPieceGuard, isFalse);
    final it = mealItemFromServer(_sushi, 0);
    expect([it.aiPieceGuard, it.kind, it.count, it.mult], [true, ItemKind.side, 1, 1.1]);
    expect(it.rawKcal, closeTo(498.3, 0.01));
    expect(it.copyWith(mult: 1.2).aiPieceGuard, isTrue, reason: '편집해도 유지');
  });

  testWidgets('인분으로 바꾼 항목: 그 카드에 배너(굵은 안내 + 확인 요청), 1,500 한 줄은 없음, 확정은 켜짐', (tester) async {
    await _open(tester, [_sushi]);
    expect(_banner(), findsOneWidget);
    expect(find.textContaining('$_guardBold$_guardRest', findRichText: true), findsOneWidget);
    final text = tester.widget<Text>(find.byWidgetPredicate((w) => w is Text && w.textSpan?.toPlainText() == '$_guardBold$_guardRest'));
    final span = (text.textSpan! as TextSpan).children!.first as TextSpan;
    expect([span.text, span.style?.fontWeight], [_guardBold, FontWeight.w600], reason: '앞 문장은 굵게');
    expect(find.text(_bigLine), findsNothing);
    expect(find.text('확인 필요'), findsOneWidget);
    final cta = tester.widget<ChButton>(_cta('확정 · 약 498 kcal'));
    expect(cta.onPressed, isNotNull);
  });

  testWidgets('1,500 kcal 넘는 항목: 조용한 한 줄, 확정은 켜짐 · 양을 줄이면 사라짐 · 가드 아닌 항목은 배너 없음', (tester) async {
    await _open(tester, [_ribs]);
    expect(find.text(_bigLine), findsOneWidget);
    expect(_banner(), findsNothing);
    expect(tester.widget<ChButton>(_cta('확정 · 약 1,800 kcal')).onPressed, isNotNull, reason: '확정은 막지 않는다');

    await tester.tap(find.byTooltip('하나 빼기'));
    await tester.pumpAndSettle();
    expect(find.text(_bigLine), findsNothing, reason: '900 kcal');
    expect(_cta('확정 · 약 900 kcal'), findsOneWidget);
  });

  testWidgets('1,500 kcal 넘는 항목이라도 먹지 않음(체크 해제)이면 한 줄 없음', (tester) async {
    await _open(tester, [_ribs, _sushi]);
    expect(find.text(_bigLine), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('갈비찜 먹었어요'));
    await tester.pumpAndSettle();
    expect(find.text(_bigLine), findsNothing);
  });
}
