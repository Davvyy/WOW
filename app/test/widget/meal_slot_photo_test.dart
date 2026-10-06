// 홈 '오늘 기록' 줄: 이 폰에 보관된 실제 사진을 작은 썸네일(32)로 보여 준다. 사진이 없으면 썸네일 없이.
import 'dart:typed_data';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/share/meal_share.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/day_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'screens_test.dart' show pumpApp, pumpWidgetScreen;

Uint8List _png() => Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));

/// 썸네일은 타일 크기로만 디코딩한다: ResizeImage 로 감싼 MemoryImage
MemoryImage? _photoOf(Image i) {
  final p = i.image;
  return p is ResizeImage && p.imageProvider is MemoryImage ? p.imageProvider as MemoryImage : null;
}

Iterable<Image> _memoryImages(WidgetTester tester) => tester.widgetList<Image>(find.byType(Image)).where((i) => _photoOf(i) != null);

void main() {
  group('DayTimelineRow 사진 썸네일', () {
    testWidgets('photo 가 있으면 32 썸네일, 타일 크기로만 디코딩', (tester) async {
      const meal = MealRecord(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 780, time: '12:20', title: '김치찌개 백반');
      await pumpWidgetScreen(tester, Scaffold(body: DayTimelineRow(meal: meal, photo: _png())));
      final images = _memoryImages(tester).toList();
      expect(images, hasLength(1));
      expect(images.single.fit, BoxFit.cover);
      expect(images.single.gaplessPlayback, isTrue);
      expect(tester.getSize(find.byType(Image)), const Size(DayTimelineRow.thumbSize, DayTimelineRow.thumbSize));
      final resize = images.single.image as ResizeImage;
      final dpr = tester.view.devicePixelRatio;
      expect(resize.width, isNotNull);
      expect(resize.height, isNotNull);
      expect(resize.width!, lessThanOrEqualTo(DayTimelineRow.thumbSize * 1.5 * dpr + 1));
      expect(resize.height!, lessThanOrEqualTo(DayTimelineRow.thumbSize * 1.5 * dpr + 1));
      expect(resize.policy, ResizeImagePolicy.fit);
    });

    testWidgets('photo 가 없으면 썸네일이 없다', (tester) async {
      const meal = MealRecord(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 780, time: '12:20', title: '김치찌개 백반');
      await pumpWidgetScreen(tester, const Scaffold(body: DayTimelineRow(meal: meal)));
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('분석 중은 사진과 함께 상태 문구', (tester) async {
      const analyzing = MealRecord(slot: MealSlot.lunch, status: MealStatus.captured, time: '12:20');
      await pumpWidgetScreen(tester, Scaffold(body: DayTimelineRow(meal: analyzing, photo: _png())));
      expect(_memoryImages(tester), hasLength(1));
      expect(find.text('분석 중…'), findsOneWidget);
      expect(find.text('12:20 · 끝나면 알려드려요'), findsOneWidget);
    });

    testWidgets('빈 칸·건너뜀은 photo 가 있어도 사진을 쓰지 않는다', (tester) async {
      const empty = MealRecord(slot: MealSlot.lunch);
      const skipped = MealRecord(slot: MealSlot.lunch, status: MealStatus.skipped);
      for (final m in [empty, skipped]) {
        await pumpWidgetScreen(tester, Scaffold(body: DayTimelineRow(meal: m, photo: _png())));
        expect(_memoryImages(tester), isEmpty);
      }
    });
  });

  group('홈 끼니 줄', () {
    testWidgets('이 폰에 보관된 사진이 있으면 그 끼니 줄에 사진이 보인다', (tester) async {
      final meals = buildTodayMeals();
      final withId = [for (final m in meals) m.slot == MealSlot.lunch ? m.copyWith(serverId: 'meal-lunch-1') : m];
      final shares = MemorySharePhotoStore()..photos['meal-lunch-1'] = _png();
      await pumpApp(tester, overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(withId)),
        sharePhotoStoreProvider.overrideWithValue(shares),
      ]);
      await tester.pumpAndSettle();
      expect(_memoryImages(tester), hasLength(1));
      final row = find.ancestor(of: find.byType(Image), matching: find.byType(DayTimelineRow));
      expect(row, findsOneWidget);
      expect(tester.widget<DayTimelineRow>(row).meal.slot, MealSlot.lunch);
    });

    testWidgets('방금 찍어 올린 사진은 줄이 바로 이어 받는다', (tester) async {
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

    testWidgets('보관된 사진이 없으면 썸네일 없이', (tester) async {
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
