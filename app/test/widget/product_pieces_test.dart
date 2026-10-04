// '몇 개입' 낱개 단위(D64): 포장 크기를 아는 상품 항목은 '낱개로 계산' → 개입 수 저장 → 1개(약 7.5g) 단위로 계산한다.
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

class _Spy extends MockChalloryApi {
  List<Map<String, dynamic>>? sent;
  @override
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey}) async {
    sent = items;
    return ConfirmResult(mealId: mealId, confirmedKcal: wireTotal(items), version: version + 1);
  }
}

/// 서버 초안 한 항목짜리 끼니(점심)
ServerMeal _draft(List<ServerMealItem> items) => ServerMeal(
      id: 'm-p',
      status: MealStatus.draft,
      version: 1,
      aiKcal: 150.3,
      slot: MealSlot.lunch,
      capturedAt: DateTime.utc(2026, 10, 13, 3, 10),
      items: items,
    );

/// 칙촉 180g 상자(1회분 30g 150.3 kcal). [serving] 은 초안의 1단위 kcal, [pieces] 는 내가 넣은 개입 수
ServerMealItem _chicItem({double serving = 150.3, int? pieces, num? packageG = 180}) => ServerMealItem(
    candidates: const ['칙촉'], candidateKcal: [serving], candidateFoodCodes: const [_chic], count: 1, portionMultiplier: 1,
    hasBroth: false, needsCheck: false, aiKcal: serving, unitLabel: '1회분(30g)', unitKcal: 150.3, servingG: 30, packageG: packageG,
    pieces: pieces);

Future<_Spy> _open(WidgetTester tester, List<ServerMealItem> items) async {
  final api = _Spy();
  await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'm-p'), overrides: [
    apiProvider.overrideWithValue(api),
    mealsProvider.overrideWith(() => MealsNotifier([
          for (final m in buildTodayMeals()) if (m.slot != MealSlot.lunch) m,
          ...mealRecordsFromServer([_draft(items)]),
        ])),
  ]);
  return api;
}

Finder _cta(String prefix) => find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith(prefix));

Future<void> _savePieces(WidgetTester tester, String n) async {
  await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), n);
  await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('저장')));
  await tester.pumpAndSettle();
}

void main() {
  test('1개 양·kcal: 180g ÷ 24 = 7.5g, 150.3 ÷ 30 × 7.5 = 37.6', () {
    expect(pieceKcal(150.3, 30, 180, 24), 37.6);
    expect(pieceLabel(180, 24), '1개(약 7.5g)');
    expect(pieceLabel(168, 24), '1개(약 7g)');
    const u = ProductUnit(unitLabel: '1회분(30g)', kcal: 150.3, servingG: 30, packageG: 180);
    expect([u.canSplit, u.label, u.unitKcal], [true, '1회분(30g)', 150.3]);
    expect([u.withPieces(24).label, u.withPieces(24).unitKcal], ['1개(약 7.5g)', 37.6]);
    expect(const ProductUnit(unitLabel: '1개(40g)', kcal: 190, servingG: 40).canSplit, isFalse);
    // 음료: 1회분이 ml 이면 낱개도 ml
    const drink = ProductUnit(unitLabel: '1회분(250ml)', kcal: 100, servingG: 250, packageG: 1500);
    expect(drink.withPieces(6).label, '1개(약 250ml)');
    expect(const ProductUnit(unitLabel: '100ml', kcal: 40, servingG: 100, packageG: 1000).withPieces(4).label, '1개(약 250ml)');
  });

  test('반올림 차이: 서버 1개 kcal(23.6)과 앱 계산(23.5)이 0.1 달라도 내 개입 수로 본다', () {
    // 157 kcal / 20g, 396g ÷ 132개 → 3g: 서버 numeric 23.55 → 23.6, 앱 double 23.549… → 23.5
    const u = ProductUnit(unitLabel: '1회분(20g)', kcal: 157, servingG: 20, packageG: 396);
    expect(pieceKcal(157, 20, 396, 132), 23.5);
    expect(u.piecesOf(23.6, saved: 132), 132);
    expect(u.piecesOf(157, saved: 132), isNull, reason: '1회분 kcal 은 1회분');
  });

  test('서버 항목: 1단위 kcal 이 1개 kcal 이면 낱개로, 1회분 kcal 이면 1회분으로 연다', () {
    final piece = mealItemFromServer(_chicItem(serving: 37.6, pieces: 24), 0);
    expect([piece.unitLabel, piece.candKcal.single, piece.product?.pieces], ['1개(약 7.5g)', 37.6, 24]);
    final whole = mealItemFromServer(_chicItem(pieces: 24), 0);
    expect([whole.unitLabel, whole.candKcal.single, whole.product?.pieces], ['1회분(30g)', 150, null], reason: '개입 수를 넣기 전에 만든 초안');
    expect([piece.kind, piece.count], [ItemKind.count, 1], reason: '낱개는 개수 항목');
    final six = mealItemFromServer(ServerMealItem(candidates: const ['칙촉'], candidateKcal: const [37.6], candidateFoodCodes: const [_chic],
        count: 6, portionMultiplier: 1, hasBroth: false, needsCheck: false, aiKcal: 225.6, unitLabel: '1회분(30g)', unitKcal: 150.3,
        servingG: 30, packageG: 180, pieces: 24), 0);
    expect([six.kind, six.count, six.mult, six.unitLabel], [ItemKind.count, 6, 1.0, '1개(약 7.5g)']);
    expect(six.rawKcal, closeTo(225.6, 1e-9));
    final w6 = mealItemToWire(six);
    expect([w6['count'], w6['portion_multiplier'], w6['serving_kcal']], [6, 1.0, 37.6]);
    expect([whole.kind, mealItemFromServer(_chicItem(), 0).withPieces(24).withPieces(null).kind], [ItemKind.side, ItemKind.side]);
    final older = mealItemFromServer(_chicItem(serving: 45.1, pieces: 24), 0);
    expect([older.unitLabel, older.product?.pieces], ['1개(약 9g)', 20], reason: '예전 개입 수(20)로 만든 초안');
    final j = ServerMealItem.fromJson({
      'chosen_name': '칙촉', 'name_candidates': ['칙촉'], 'candidate_kcal': [37.6], 'candidate_food_codes': [_chic], 'count': 1,
      'portion_multiplier': 2, 'food_db_cache': {'unit_label': '1회분(30g)', 'kcal': 150.3, 'serving_g': 30, 'package_g': 180,
        'user_product_pieces': [{'pieces': 24}]},
    });
    expect([j.unitKcal, j.servingG, j.packageG, j.pieces], [150.3, 30, 180, 24]);
  });

  testWidgets("'낱개로 계산' → 24개입 저장 → 1개(약 7.5g) 37.6 kcal 개수 항목, 6개 → 확정은 count 6 × 1개 kcal", (tester) async {
    final api = await _open(tester, [_chicItem()]);
    expect(find.text('가정 분량 · 1회분(30g)'), findsOneWidget);
    await tester.tap(find.text('낱개로 계산'));
    await tester.pumpAndSettle();
    expect(find.text('상자(포장)에 몇 개 들어 있나요?'), findsOneWidget);
    expect(find.text('포장에 적힌 ○개입 숫자를 넣어 주세요'), findsOneWidget);
    expect(find.text('1회분 기준으로 되돌리기'), findsNothing, reason: '아직 개입 수가 없음');

    await _savePieces(tester, '1');
    expect(find.byType(Dialog), findsOneWidget, reason: '2~200 밖은 저장하지 않음');
    expect(api.productPieces, isEmpty);
    await _savePieces(tester, '24');
    expect(api.productPieces, {_chic: 24});
    expect(find.text('가정 분량 · 1개(약 7.5g) × 1'), findsOneWidget);
    expect(find.text('1.0배'), findsOneWidget, reason: '개수 항목: 1개 크기 1.0배');
    expect(find.text('낱개 24개 기준 · 바꾸기'), findsOneWidget);
    expect(_cta('확정 · 약 38 kcal'), findsOneWidget, reason: '37.6 × 1');

    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byTooltip('하나 더하기'));
      await tester.pumpAndSettle();
    }
    expect(find.text('가정 분량 · 1개(약 7.5g) × 6'), findsOneWidget, reason: '3개를 넘어 6개까지');
    expect(_cta('확정 · 약 226 kcal'), findsOneWidget, reason: '37.6 × 6 = 225.6');
    await tester.tap(_cta('확정'));
    await tester.pumpAndSettle();
    final w = api.sent!.single;
    expect([w['food_code'], w['serving_kcal'], w['portion_multiplier'], w['count']], [_chic, 37.6, 1.0, 6]);
    expect(wireTotal(api.sent!), 225.6);
  });

  testWidgets("'1회분 기준으로 되돌리기' → 개입 수를 지우고 1회분(30g) 150 kcal 로", (tester) async {
    final api = await _open(tester, [_chicItem(serving: 37.6, pieces: 24)]);
    api.productPieces[_chic] = 24;
    expect(find.text('가정 분량 · 1개(약 7.5g) × 1'), findsOneWidget);
    await tester.tap(find.text('낱개 24개 기준 · 바꾸기'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField))).controller!.text, '24');
    await tester.tap(find.text('1회분 기준으로 되돌리기'));
    await tester.pumpAndSettle();
    expect(api.productPieces, isEmpty);
    expect(find.text('가정 분량 · 1회분(30g)'), findsOneWidget);
    expect(find.text('1.0회분'), findsOneWidget);
    expect(find.text('낱개로 계산'), findsOneWidget);
    expect(_cta('확정 · 약 150 kcal'), findsOneWidget);
  });

  testWidgets('저장 오류는 apiErrorText 로 알리고 항목은 그대로', (tester) async {
    final api = await _open(tester, [_chicItem()]);
    api.failNext = const ApiException(422, '포장 크기를 아는 상품만 낱개로 계산할 수 있어요');
    await tester.tap(find.text('낱개로 계산'));
    await tester.pumpAndSettle();
    await _savePieces(tester, '24');
    expect(find.text('포장 크기를 아는 상품만 낱개로 계산할 수 있어요'), findsOneWidget);
    expect(find.text('가정 분량 · 1회분(30g)'), findsOneWidget);
  });

  testWidgets("음식·포장 크기 없는 상품에는 '낱개로 계산'이 없다", (tester) async {
    await _open(tester, [
      _chicItem(packageG: null),
      const ServerMealItem(candidates: ['초코칩쿠키'], candidateKcal: [308], candidateFoodCodes: ['D000070'], count: 1, portionMultiplier: 1,
          hasBroth: false, needsCheck: false, aiKcal: 308),
    ]);
    expect(find.text('가정 분량 · 1회분(30g)'), findsOneWidget);
    expect(find.text('낱개로 계산'), findsNothing);
    expect(find.textContaining('낱개'), findsNothing);
  });

  test('모의 API: 개입 수 저장·지우기, 범위 밖은 422', () async {
    final api = MockChalloryApi();
    await api.setProductPieces(_chic, 24);
    expect(api.productPieces, {_chic: 24});
    await api.setProductPieces(_chic, null);
    expect(api.productPieces, isEmpty);
    await expectLater(api.setProductPieces(_chic, 201), throwsA(isA<ApiException>().having((e) => e.status, 'status', 422)));
  });

  test('확정 형식: 낱개 항목은 serving_kcal = 1개 kcal(소수 1자리)', () {
    final it = mealItemFromServer(_chicItem(serving: 37.6, pieces: 24), 0).copyWith(mult: 3);
    expect([mealItemToWire(it)['serving_kcal'], mealItemToWire(it)['portion_multiplier'], it.rawKcal], [37.6, 3.0, closeTo(112.8, 1e-9)]);
  });
}
