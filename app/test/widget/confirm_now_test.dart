// '지금 확정': 사진을 올린 뒤 P7 이 AI 분석을 기다렸다가 초안 항목을 띄운다(예시 항목으로 채우지 않음)
import 'dart:typed_data';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;

import 'screens_test.dart' show pumpApp;

/// 분석 결과 '음식을 찾지 못함'
class _NoFoodApi extends MockChalloryApi {
  @override
  Future<ServerMeal?> fetchMeal(String mealId) async => ServerMeal(id: mealId, status: MealStatus.failed, version: 1);
}

Uint8List _jpeg() => Uint8List.fromList(img.encodeJpg(img.Image(width: 200, height: 150)));

void main() {
  testWidgets('촬영 후 끼니가 만들어지면 그 슬롯을 알려 준다', (tester) async {
    final container = ProviderContainer(overrides: [mealsProvider.overrideWith(() => MealsNotifier(buildTodayMeals()))]);
    addTearDown(container.dispose);
    final meals = container.read(mealsProvider.notifier);
    expect(meals.lastCapturedSlot, isNull);
    await tester.runAsync(() => meals.capture(MealSlot.lunch, '12:20', photo: _jpeg(), capturedAt: DateTime.now()));
    final slot = meals.lastCapturedSlot;
    expect(slot, isNotNull);
    final rec = meals.byKey(meals.lastCapturedKey!)!;
    expect(rec.slot, slot);
    expect(rec.serverId, isNotNull);
    expect(rec.status, MealStatus.captured);
  });

  testWidgets('P7 분석 중이면 기다림 안내 → 초안이 오면 그 항목으로 바뀐다', (tester) async {
    final api = MockChalloryApi(analysisDelay: const Duration(milliseconds: 500));
    final container = await pumpApp(tester, overrides: [
      apiProvider.overrideWithValue(api),
      mealsProvider.overrideWith(() => MealsNotifier(buildTodayMeals())),
    ]);
    final meals = container.read(mealsProvider.notifier);
    await tester.runAsync(() => meals.capture(MealSlot.lunch, '12:20', photo: _jpeg(), capturedAt: DateTime.now()));
    final slot = meals.lastCapturedSlot!;
    final key = meals.lastCapturedKey!;
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push(R.meal(slot, meal: key));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // 기다림 화면은 로딩 표시가 계속 돈다
    expect(find.textContaining('AI가 음식을 보고 있어요'), findsOneWidget);
    expect(find.textContaining('확정 · 약'), findsNothing, reason: '분석 전에는 예시 항목으로 확정하지 않는다');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    final shown = find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).image?.image is MemoryImage);
    expect(shown, findsOneWidget, reason: '찍은 사진을 위쪽에 보여 준다');

    // 모의 서버 분석 지연(0.5초) 뒤 1.5초 간격 확인 → 초안
    await tester.runAsync(() async {
      for (var i = 0; i < 40 && meals.byKey(key)!.status != MealStatus.draft; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(meals.byKey(key)!.status, MealStatus.draft);
    expect(find.textContaining('AI가 음식을 보고 있어요'), findsNothing);
    expect(find.textContaining('확정 · 약 ${mockAiTotal(slot).round()}'), findsOneWidget);
  });

  testWidgets('P7 분석 중에 분석 불가로 바뀌면 검색 화면', (tester) async {
    final container = await pumpApp(tester, overrides: [
      apiProvider.overrideWithValue(_NoFoodApi()),
      mealsProvider.overrideWith(() => MealsNotifier(buildTodayMeals())),
    ]);
    final meals = container.read(mealsProvider.notifier);
    await tester.runAsync(() => meals.capture(MealSlot.lunch, '12:20', photo: _jpeg(), capturedAt: DateTime.now()));
    final slot = meals.lastCapturedSlot!;
    final key = meals.lastCapturedKey!;
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push(R.meal(slot, meal: key));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // 기다림 화면은 로딩 표시가 계속 돈다
    expect(find.textContaining('AI가 음식을 보고 있어요'), findsOneWidget);
    await tester.runAsync(() async {
      for (var i = 0; i < 40 && meals.byKey(key)!.status != MealStatus.failed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('음식을 찾지 못했어요'), findsOneWidget);
  });
}
