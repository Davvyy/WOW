// 식사 공유 카드·미리보기 시트·P7 진입점
import 'dart:typed_data';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/share/meal_share.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/meal_share_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'screens_test.dart' show pumpApp, pumpWidgetScreen;

class _FakeSharer implements MealSharer {
  final calls = <(Uint8List, String, String)>[];
  @override
  Future<void> shareImage(Uint8List png, {required String fileName, required String text}) async => calls.add((png, fileName, text));
}

Uint8List _png() => Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));

const _data = MealShareData(
  title: '10.5 점심',
  lines: [ShareLine('비빔밥', 560), ShareLine('된장국', 120)],
  moreCount: 2,
  total: 680,
);

void main() {
  group('MealShareCard', () {
    testWidgets('제목·음식·합계·로고·추정 고지, 닉네임·점수는 없음', (tester) async {
      await pumpWidgetScreen(tester, const Scaffold(body: Center(child: MealShareCard(data: _data))));
      for (final t in ['10.5 점심', '비빔밥', '560', '된장국', '120', '외 2개', '680', '챌로리', 'kcal은 추정치예요']) {
        expect(find.textContaining(t), findsWidgets, reason: t);
      }
      expect(find.textContaining(curMe.nickname), findsNothing);
      expect(find.textContaining('점수'), findsNothing);
      expect(find.textContaining('순위'), findsNothing);
      expect(find.byType(Image).evaluate().where((e) => (e.widget as Image).image is MemoryImage), isEmpty);
      expect(tester.getSize(find.byType(MealShareCard)), MealShareCard.size);
    });

    testWidgets('사진이 있으면 사진을 보여 준다', (tester) async {
      final withPhoto = MealShareData(title: _data.title, lines: _data.lines, moreCount: 0, total: 680, photo: _png());
      await pumpWidgetScreen(tester, Scaffold(body: Center(child: MealShareCard(data: withPhoto))));
      expect(find.byType(Image).evaluate().where((e) => (e.widget as Image).image is MemoryImage), hasLength(1));
    });
  });

  group('P7 공유', () {
    testWidgets('확정된 끼니는 공유 아이콘 → 미리보기 → 공유 창에 PNG·문구 전달', (tester) async {
      final sharer = _FakeSharer();
      final shares = MemorySharePhotoStore();
      final meals = buildTodayMeals();
      final lunch = meals.firstWhere((m) => m.slot == MealSlot.lunch);
      expect(canShareMeal(lunch), isTrue);
      await pumpApp(tester, location: R.meal(MealSlot.lunch), overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(meals)),
        mealSharerProvider.overrideWithValue(sharer),
        sharePhotoStoreProvider.overrideWithValue(shares),
      ]);
      await tester.tap(find.byTooltip('공유'));
      await tester.pumpAndSettle();
      expect(find.byType(MealShareCard), findsOneWidget);
      expect(find.textContaining('닉네임·점수는 들어가지 않아요'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('공유하기'));
        for (var i = 0; i < 20 && sharer.calls.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      expect(sharer.calls, hasLength(1));
      final (png, name, text) = sharer.calls.single;
      expect(png.sublist(1, 4), 'PNG'.codeUnits);
      expect(name, endsWith('.png'));
      expect(text, contains('점심'));
      expect(text, contains('#챌로리'));
    });

    testWidgets('직접 찍은 끼니(나중에 확정)를 확정하면 카드에 그 사진이 들어간다', (tester) async {
      final container = await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(buildTodayMeals()))]);
      final meals = container.read(mealsProvider.notifier);
      final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 200, height: 150)));
      String? err;
      await tester.runAsync(() async => err = await meals.capture(MealSlot.lunch, '12:20', photo: jpeg, capturedAt: DateTime.now()));
      expect(err, isNull);
      final shot = container.read(mealsProvider).firstWhere((m) => m.serverId != null);
      expect(await container.read(sharePhotoStoreProvider).get(shot.serverId!), isNotNull);
      await tester.runAsync(() => meals.confirm(shot.slot, const [MealItem(id: 'a', candidates: ['비빔밥'], candKcal: [560], portion: '1인분', kind: ItemKind.count)], 560));
      await tester.pumpAndSettle();
      showMealShareSheet(tester.element(find.byType(Scaffold).first), shot.slot);
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.byType(Image).evaluate().where((e) => (e.widget as Image).image is MemoryImage), hasLength(1));
    });

    testWidgets('AI 초안은 공유 아이콘이 없다', (tester) async {
      await pumpApp(tester, location: R.meal(MealSlot.lunch), overrides: [mealsProvider.overrideWith(() => MealsNotifier(buildLunchDraftMeals()))]);
      expect(find.byTooltip('공유'), findsNothing);
    });

    testWidgets('확정 직후 홈 스낵바에 공유 버튼', (tester) async {
      await pumpApp(tester, location: R.meal(MealSlot.lunch), overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(buildLunchDraftMeals())),
        mealSharerProvider.overrideWithValue(_FakeSharer()),
      ]);
      await tester.tap(find.textContaining('확정 · 약 850'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.textContaining('점심을 확정했어요'), findsOneWidget);
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).persist, isFalse, reason: '공유 버튼이 있어도 시간이 지나면 닫혀야 한다');
      expect(find.widgetWithText(SnackBarAction, '공유'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, '공유'));
      await tester.pumpAndSettle();
      expect(find.byType(MealShareCard), findsOneWidget);
    });
  });
}
