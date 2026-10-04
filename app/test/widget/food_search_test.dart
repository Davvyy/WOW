// P7 음식 검색 시트: 최근 음식 → 검색어 입력(250 ms 뒤 서버 검색) → 고르면 1인분 kcal·food_code 항목 → 확정 시 input_type=search
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SearchSpy extends MockChalloryApi {
  List<Map<String, dynamic>>? confirmedWire;
  @override
  Future<List<FoodHit>> searchFoods(String q) async {
    calls.add('food_search:$q');
    // 서버 food_search 응답 모양(name_kr·food_code·kcal)
    return [
      foodHitFromServer({'food_code': 'D000060', 'name_kr': '곰탕', 'kcal': 330, 'serving_g': 600, 'score': 1.0}),
    ];
  }

  @override
  Future<ConfirmResult> createManualMeal(MealSlot slot, List<Map<String, dynamic>> items, {String? localDate, required String idempotencyKey}) {
    confirmedWire = items;
    return super.createManualMeal(slot, items, localDate: localDate, idempotencyKey: idempotencyKey);
  }
}

void main() {
  _productTests();

  test('food_search 행 → 검색 결과', () {
    final h = foodHitFromServer({'food_code': 'D000001', 'name_kr': '흰쌀밥', 'kcal': 310.4});
    expect([h.name, h.kcal, h.foodCode, h.recent], ['흰쌀밥', 310, 'D000001', false]);
    expect(foodHitFromServer({'name': '엄마표 김밥', 'food_code': null, 'kcal': 350}, recent: true).recent, isTrue);
  });

  testWidgets('검색 시트: 최근 음식 → "설렁탕" 검색 → 곰탕 선택 → 확정 시 food_code·search 로 전송', (tester) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _SearchSpy();
    final router = buildRouter(initialLocation: R.meal(MealSlot.dinner, search: true));
    addTearDown(router.dispose);
    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    container.read(mealsProvider.notifier).reset([for (final s in MealSlot.values) MealRecord(slot: s)]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('음식 이름 검색 · 최근 음식'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('recent_foods'));
    expect(find.text('최근 음식'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '음식 이름 검색 (식약처 DB)'), '설렁탕');
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.calls.where((c) => c.startsWith('food_search')), isEmpty, reason: '250 ms 디바운스');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(api.calls, contains('food_search:설렁탕'));
    expect(find.text('검색 결과 1건'), findsOneWidget);

    await tester.tap(find.text('곰탕 '));
    await tester.pumpAndSettle();
    expect(find.text('곰탕'), findsWidgets);

    await tester.tap(find.text('확정 · 약 330 kcal'));
    await tester.pumpAndSettle();
    expect(api.confirmedWire, isNotNull);
    final item = api.confirmedWire!.single;
    expect([item['chosen_name'], item['food_code'], item['serving_kcal'], item['input_type']], ['곰탕', 'D000060', 330, 'search']);
  });
}

/// 서버 food_search 가 음식과 상품(D63)을 함께 돌려주는 모양
class _ProductSearchSpy extends _SearchSpy {
  @override
  Future<List<FoodHit>> searchFoods(String q) async {
    calls.add('food_search:$q');
    return [
      foodHitFromServer({'food_code': 'P101-103000100-5334', 'name_kr': '칙촉', 'kcal': 150.3, 'serving_g': 30, 'score': 1.0,
        'is_product': true, 'maker': '롯데웰푸드 주식회사', 'unit_label': '1회분(30g)'}),
      foodHitFromServer({'food_code': 'D000070', 'name_kr': '초코칩쿠키', 'kcal': 308, 'serving_g': 70, 'score': 0.3, 'is_product': false}),
    ];
  }
}

void _productTests() {
  testWidgets('검색 시트: 상품은 제조사·단위 라벨과 1개 kcal, 고르면 단위(회분)로 먹은 양을 고친다', (tester) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _ProductSearchSpy();
    final router = buildRouter(initialLocation: R.meal(MealSlot.snack, search: true));
    addTearDown(router.dispose);
    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    container.read(mealsProvider.notifier).reset([for (final s in MealSlot.values) MealRecord(slot: s)]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('음식 이름 검색 · 최근 음식'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '음식 이름 검색 (식약처 DB)'), '칙촉');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('칙촉 · 롯데웰푸드 · 1회분(30g) '), findsOneWidget);
    expect(find.text('초코칩쿠키 '), findsOneWidget, reason: '음식 행은 이름만');

    await tester.tap(find.text('칙촉 · 롯데웰푸드 · 1회분(30g) '));
    await tester.pumpAndSettle();
    expect(find.text('가정 분량 · 1회분(30g)'), findsOneWidget);
    expect(find.text('1.0회분'), findsOneWidget);
    expect(find.text('확정 · 약 150 kcal'), findsOneWidget);

    await tester.tap(find.byTooltip('더 먹음'));
    await tester.pumpAndSettle();
    expect(find.text('2.0회분'), findsNothing);
    await tester.tap(find.text('2').last);
    await tester.pumpAndSettle();
    expect(find.text('2.0회분'), findsOneWidget);
    expect(find.text('확정 · 약 300 kcal'), findsOneWidget);

    await tester.tap(find.text('확정 · 약 300 kcal'));
    await tester.pumpAndSettle();
    final item = api.confirmedWire!.single;
    expect([item['chosen_name'], item['food_code'], item['serving_kcal'], item['count'], item['portion_multiplier'], item['input_type']],
        ['칙촉', 'P101-103000100-5334', 150, 1, 2.0, 'search']);
  });
}
