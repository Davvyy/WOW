// 홈 끼니 카드: 이 폰에 보관된 실제 사진을 썸네일로 보여 준다
import 'dart:typed_data';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/share/meal_share.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/meal_slot_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'screens_test.dart' show pumpApp, pumpWidgetScreen;

Uint8List _png() => Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));

Iterable<Image> _memoryImages(WidgetTester tester) =>
    tester.widgetList<Image>(find.byType(Image)).where((i) => i.image is MemoryImage);

void main() {
  group('MealSlotCard 사진 썸네일', () {
    testWidgets('photo 가 있으면 Image.memory 로 보여 준다', (tester) async {
      const meal = MealRecord(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 780, time: '12:20', title: '김치찌개 백반');
      await pumpWidgetScreen(tester, Scaffold(body: MealSlotCard(meal: meal, photo: _png())));
      final images = _memoryImages(tester).toList();
      expect(images, hasLength(1));
      expect(images.single.fit, BoxFit.cover);
      expect(images.single.gaplessPlayback, isTrue);
    });

    testWidgets('photo 가 없으면 사진 이미지가 없다', (tester) async {
      const meal = MealRecord(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 780, time: '12:20', title: '김치찌개 백반');
      await pumpWidgetScreen(tester, const Scaffold(body: MealSlotCard(meal: meal)));
      expect(_memoryImages(tester), isEmpty);
    });

    testWidgets('분석 중·업로드 대기는 사진 위에 상태 아이콘이 남는다', (tester) async {
      const analyzing = MealRecord(slot: MealSlot.lunch, status: MealStatus.captured, time: '12:20');
      await pumpWidgetScreen(tester, Scaffold(body: MealSlotCard(meal: analyzing, photo: _png())));
      expect(_memoryImages(tester), hasLength(1));
      // 배지(칩) 아이콘 + 사진 위 아이콘
      expect(find.byIcon(Icons.hourglass_top_rounded), findsNWidgets(2));
    });

    testWidgets('빈 칸·건너뜀은 photo 가 있어도 사진을 쓰지 않는다', (tester) async {
      const empty = MealRecord(slot: MealSlot.lunch);
      const skipped = MealRecord(slot: MealSlot.lunch, status: MealStatus.skipped);
      for (final m in [empty, skipped]) {
        await pumpWidgetScreen(tester, Scaffold(body: MealSlotCard(meal: m, photo: _png())));
        expect(_memoryImages(tester), isEmpty);
      }
    });
  });

  group('홈 끼니 카드', () {
    testWidgets('이 폰에 보관된 사진이 있으면 그 끼니 카드에 사진이 보인다', (tester) async {
      final meals = buildTodayMeals();
      final withId = [for (final m in meals) m.slot == MealSlot.lunch ? m.copyWith(serverId: 'meal-lunch-1') : m];
      final shares = MemorySharePhotoStore()..photos['meal-lunch-1'] = _png();
      await pumpApp(tester, overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(withId)),
        sharePhotoStoreProvider.overrideWithValue(shares),
      ]);
      await tester.pumpAndSettle();
      expect(_memoryImages(tester), hasLength(1));
      final card = find.ancestor(of: find.byType(Image), matching: find.byType(MealSlotCard));
      expect(card, findsOneWidget);
      expect(tester.widget<MealSlotCard>(card).meal.slot, MealSlot.lunch);
    });

    testWidgets('방금 찍어 올린 사진은 카드가 바로 이어 받는다', (tester) async {
      final container = await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(buildTodayMeals()))]);
      await tester.pumpAndSettle();
      expect(_memoryImages(tester), isEmpty);
      final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 200, height: 150)));
      String? err;
      await tester.runAsync(() async => err = await container.read(mealsProvider.notifier).capture(MealSlot.lunch, '12:20', photo: jpeg, capturedAt: DateTime.now()));
      expect(err, isNull);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(_memoryImages(tester), hasLength(1));
    });

    testWidgets('보관된 사진이 없으면 아이콘 썸네일 그대로', (tester) async {
      final withId = [for (final m in buildTodayMeals()) m.slot == MealSlot.lunch ? m.copyWith(serverId: 'meal-lunch-1') : m];
      await pumpApp(tester, overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(withId)),
        sharePhotoStoreProvider.overrideWithValue(MemorySharePhotoStore()),
      ]);
      await tester.pumpAndSettle();
      expect(_memoryImages(tester), isEmpty);
    });
  });
}
