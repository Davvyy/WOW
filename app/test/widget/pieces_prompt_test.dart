// '몇 개입' 안내(D67): AI 가 낱개 포장 하나로 본 포장 상품은 배너로, 1회분 단위 상품은 조용한 한 줄로 개입 수를 묻는다.
// 개입 수로 단위를 바꾸는 것은 단위 정정이라 AI 초안도 같은 단위로 맞춰 하향 확인 창을 띄우지 않는다.
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

const _chic = 'P101-103000100-5334';
const _bannerBold = '낱개 포장 한 개로 보여요.';
const _bannerAction = '몇 개입인지 넣기';
const _hint = '낱개 포장이면 몇 개입인지 넣어 주세요';
const _downward = 'AI 추정보다 50% 넘게 낮아요';

class _Spy extends MockChalloryApi {
  List<Map<String, dynamic>>? sent;
  @override
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey}) async {
    sent = items;
    return ConfirmResult(mealId: mealId, confirmedKcal: wireTotal(items), version: version + 1);
  }
}

/// 칙촉 180g 상자(1회분 30g 150.3 kcal) 낱개 봉지 사진의 초안 항목. [single] 은 AI 낱개 표시, [pieces] 는 내가 넣어 둔 개입 수
ServerMealItem _chicItem({bool single = true, double serving = 150.3, int? pieces, int count = 1, String unitLabel = '1회분(30g)'}) =>
    ServerMealItem(
        candidates: const ['칙촉'], candidateKcal: [serving], candidateFoodCodes: const [_chic], count: count, portionMultiplier: 1,
        hasBroth: false, needsCheck: false, aiKcal: round1(serving * count), unitLabel: unitLabel, unitKcal: 150.3, servingG: 30,
        packageG: 180, pieces: pieces, aiSinglePiece: single);

Future<_Spy> _open(WidgetTester tester, List<ServerMealItem> items) async {
  final api = _Spy();
  await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'm-p'), overrides: [
    apiProvider.overrideWithValue(api),
    mealsProvider.overrideWith(() => MealsNotifier([
          for (final m in buildTodayMeals()) if (m.slot != MealSlot.lunch) m,
          ...mealRecordsFromServer([
            ServerMeal(
              id: 'm-p',
              status: MealStatus.draft,
              version: 1,
              aiKcal: round1(items.fold<double>(0, (a, i) => a + i.aiKcal)),
              slot: MealSlot.lunch,
              capturedAt: DateTime.utc(2026, 10, 13, 3, 10),
              items: items,
            ),
          ]),
        ])),
  ]);
  return api;
}

Finder _cta(String prefix) => find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith(prefix));
Finder _banner() => find.textContaining(_bannerBold, findRichText: true);

Future<void> _savePieces(WidgetTester tester, String n) async {
  await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), n);
  await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('저장')));
  await tester.pumpAndSettle();
}

void main() {
  test('안내 종류: 낱개 표시 → 배너, 표시 없는 1회분 → 한 줄, 개입 수가 있거나 포장 전체·음식이면 없음', () {
    PiecesPrompt of(ServerMealItem s) => mealItemFromServer(s, 0).piecesPrompt;
    expect(of(_chicItem()), PiecesPrompt.banner);
    expect(of(_chicItem(single: false)), PiecesPrompt.hint);
    expect(of(_chicItem(pieces: 24)), PiecesPrompt.none, reason: '개입 수를 넣어 둔 상품(1회분 초안이어도)');
    expect(of(_chicItem(serving: 37.6, pieces: 24)), PiecesPrompt.none, reason: '이미 1개 단위');
    expect(of(_chicItem(unitLabel: '1개(46g)')), PiecesPrompt.none, reason: '단위가 이미 포장 전체');
    expect(of(_chicItem(single: false, unitLabel: '100g')), PiecesPrompt.none, reason: '1회분이 아닌 기준량은 표시 없으면 묻지 않음');
    expect(of(_chicItem(unitLabel: '100g')), PiecesPrompt.banner, reason: '낱개 표시면 기준량 단위도 묻는다');
    const dish = ServerMealItem(candidates: ['초코칩쿠키'], candidateKcal: [308], candidateFoodCodes: ['D000070'], count: 1, portionMultiplier: 1,
        hasBroth: false, needsCheck: false, aiKcal: 308, aiSinglePiece: true);
    expect(of(dish), PiecesPrompt.none, reason: '음식 항목은 묻지 않음');
  });

  test('서버 항목: ai_single_piece 를 읽고(없으면 false), AI 초안 몫과 양을 기억한다', () {
    Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) => {
          'chosen_name': '칙촉', 'name_candidates': ['칙촉'], 'candidate_kcal': [150.3], 'candidate_food_codes': [_chic], 'count': 2,
          'portion_multiplier': 1.0, 'ai_kcal': 300.6, ...extra,
        };
    expect(ServerMealItem.fromJson(row({'ai_single_piece': true})).aiSinglePiece, isTrue);
    expect(ServerMealItem.fromJson(row()).aiSinglePiece, isFalse);
    final it = mealItemFromServer(_chicItem(count: 2), 0);
    expect([it.aiSinglePiece, it.aiKcal, it.aiUnits], [true, 300.6, 2.0]);
    expect(it.copyWith(checked: false).aiSinglePiece, isTrue, reason: '편집해도 유지');
    final confirmed = mealItemFromServer(ServerMealItem.fromJson(row({'ai_kcal': null, 'confirmed_kcal': 300.6})), 0);
    expect([confirmed.aiKcal, confirmed.aiUnits], [null, null], reason: '확정한 항목은 AI 몫이 없다');
  });

  testWidgets("낱개 표시 → 배너 '몇 개입인지 넣기' → 24 → 1개(약 7.5g) 37.6, 배너가 사라지고 확정은 하향 확인 없이", (tester) async {
    final api = await _open(tester, [_chicItem()]);
    expect(_banner(), findsOneWidget);
    expect(find.textContaining('상자에 몇 개 들어 있는지 넣으면 한 개 기준으로 계산해요.', findRichText: true), findsOneWidget);
    expect(find.text(_hint), findsNothing, reason: '배너가 있으면 한 줄 안내는 없음');
    expect(_cta('확정 · 약 150 kcal'), findsOneWidget);

    await tester.tap(find.text(_bannerAction));
    await tester.pumpAndSettle();
    expect(find.text('상자(포장)에 몇 개 들어 있나요?'), findsOneWidget, reason: '기존 개입 수 창(D64)');
    await _savePieces(tester, '24');
    expect(api.productPieces, {_chic: 24});
    expect(find.text('가정 분량 · 1개(약 7.5g) × 1'), findsOneWidget);
    expect(find.text('38'), findsWidgets, reason: '항목 37.6 kcal');
    expect(_cta('확정 · 약 38 kcal'), findsOneWidget);
    expect(_banner(), findsNothing);
    expect(find.text(_bannerAction), findsNothing);
    expect(find.textContaining('AI 초안 약 38'), findsOneWidget, reason: 'AI 초안도 1개 단위(37.6 × 1)로');

    await tester.tap(_cta('확정'));
    await tester.pumpAndSettle();
    expect(find.text(_downward), findsNothing, reason: '단위 정정은 하향 확인 창을 띄우지 않음');
    final w = api.sent!.single;
    expect([w['food_code'], w['serving_kcal'], w['count'], w['portion_multiplier']], [_chic, 37.6, 1, 1.0]);
  });

  testWidgets('AI 가 3봉지로 본 항목은 1개 단위 AI 초안도 3개(112.8): 1개만 확정하면 하향 확인은 그대로', (tester) async {
    final api = await _open(tester, [_chicItem(count: 3)]);
    await tester.tap(find.text(_bannerAction));
    await tester.pumpAndSettle();
    await _savePieces(tester, '24');
    expect(find.textContaining('AI 초안 약 113'), findsOneWidget, reason: '37.6 × 3 = 112.8');
    await tester.tap(_cta('확정 · 약 38 kcal'));
    await tester.pumpAndSettle();
    expect(find.text(_downward), findsOneWidget, reason: '37.6 / 112.8 → AI 보다 50% 넘게 낮음');
    await tester.tap(find.text('다시 볼게요'));
    await tester.pumpAndSettle();
    expect(api.sent, isNull);
  });

  testWidgets('배너 닫기 → 이 화면에서 다시 보이지 않고 낱개로 계산 링크는 그대로', (tester) async {
    await _open(tester, [_chicItem()]);
    expect(_banner(), findsOneWidget);
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(_banner(), findsNothing);
    expect(find.text(_hint), findsNothing, reason: '닫은 항목은 한 줄 안내로 바꾸지 않음');
    expect(find.text('낱개로 계산'), findsOneWidget);
    expect(_cta('확정 · 약 150 kcal'), findsOneWidget);
  });

  testWidgets("표시 없는 1회분 상품 → 조용한 한 줄 + '낱개로 계산', 저장하면 사라진다", (tester) async {
    final api = await _open(tester, [_chicItem(single: false)]);
    expect(find.text(_hint), findsOneWidget);
    expect(_banner(), findsNothing);
    await tester.tap(find.text('낱개로 계산'));
    await tester.pumpAndSettle();
    await _savePieces(tester, '24');
    expect(find.text(_hint), findsNothing);
    expect(find.text('낱개 24개 기준 · 바꾸기'), findsOneWidget);
    await tester.tap(_cta('확정 · 약 38 kcal'));
    await tester.pumpAndSettle();
    expect(find.text(_downward), findsNothing);
    expect(api.sent, isNotNull);
  });

  testWidgets('개입 수를 넣어 둔 상품·음식 항목에는 안내가 없다', (tester) async {
    await _open(tester, [
      _chicItem(pieces: 24),
      const ServerMealItem(candidates: ['초코칩쿠키'], candidateKcal: [308], candidateFoodCodes: ['D000070'], count: 1, portionMultiplier: 1,
          hasBroth: false, needsCheck: false, aiKcal: 308, aiSinglePiece: true),
    ]);
    expect(_banner(), findsNothing);
    expect(find.text(_bannerAction), findsNothing);
    expect(find.text(_hint), findsNothing);
    expect(find.text('낱개로 계산'), findsOneWidget, reason: '링크는 그대로');
  });

  test('모의 API: 초안 항목을 넣으면 그 항목(낱개 표시 포함)과 AI 합계로 초안을 돌려준다', () async {
    final api = MockChalloryApi(analysisDelay: Duration.zero)..draftItems = [_chicItem(), _chicItem(single: false)];
    final created = await api.createMeal('ph', queued: false, idempotencyKey: 'k', slot: MealSlot.snack);
    final m = await api.fetchMeal(created.mealId);
    expect(m!.status, MealStatus.draft);
    expect(m.items.map((i) => i.aiSinglePiece), [true, false]);
    expect(m.aiKcal, 300.6);
  });
}
