// 홈: 한 슬롯의 끼니를 모두 한 줄씩 보여 주고, 누른 그 끼니의 P7 을 연다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/screens/p6_camera.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:challory/ui/widgets/meal_slot_card.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 기본 시드 + 아침에 서버 끼니 하나 더(요거트 볼 300)
List<MealRecord> _twoBreakfasts() => [
      ...buildTodayMeals(),
      const MealRecord(
        slot: MealSlot.breakfast,
        status: MealStatus.confirmed,
        kcal: 300,
        title: '요거트 볼',
        time: '10:10',
        serverId: 'm-b2',
        version: 2,
        items: [MealItem(id: 'y', candidates: ['요거트 볼'], candKcal: [300], portion: '1그릇', kind: ItemKind.count)],
      ),
    ];

Finder _rowsOf(MealSlot s) => find.byWidgetPredicate((w) => w is MealRow && w.meal.slot == s);

void main() {
  testWidgets('홈 아침 카드: 끼니 2개면 2줄 · 머리글은 반영 kcal 합계 · 두 번째를 누르면 그 끼니의 P7', (tester) async {
    await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(_twoBreakfasts()))]);
    expect(_rowsOf(MealSlot.breakfast), findsNWidgets(2));
    expect(_rowsOf(MealSlot.lunch), findsOneWidget);
    expect(find.bySemanticsLabel('아침 720 kcal'), findsOneWidget);
    expect(find.text('요거트 볼'), findsOneWidget);
    expect(find.bySemanticsLabel('아침 추가'), findsOneWidget);
    // 기록이 없는 간식은 지금처럼 촬영 칸
    expect(find.byWidgetPredicate((w) => w is MealSlotCard && w.meal.slot == MealSlot.snack && w.meal.status == MealStatus.empty), findsOneWidget);

    await tester.tap(_rowsOf(MealSlot.breakfast).at(1));
    await tester.pumpAndSettle();
    expect(find.text('아침 확인'), findsOneWidget);
    expect(find.textContaining('아침 · 10:10'), findsOneWidget);
    expect(find.text('요거트 볼'), findsWidgets);
    expect(find.textContaining('확정 · 약 300 kcal'), findsOneWidget);
  });

  testWidgets("'추가'는 그 슬롯을 고른 촬영 화면을 연다", (tester) async {
    await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(_twoBreakfasts()))]);
    await tester.tap(find.descendant(of: find.byWidgetPredicate((w) => w is MealSlotGroupCard && w.slot == MealSlot.breakfast), matching: find.text('추가')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<CameraScreen>(find.byType(CameraScreen)).initialSlot, MealSlot.breakfast);
  });

  testWidgets('끼니가 있는 슬롯의 P7 은 건너뜀을 끈다(건너뜀은 빈 슬롯에서만)', (tester) async {
    await pumpApp(tester, location: R.meal(MealSlot.breakfast, meal: 'm-b2'), overrides: [mealsProvider.overrideWith(() => MealsNotifier(_twoBreakfasts()))]);
    final skip = tester.widget<ChButton>(find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith('건너뜀')));
    expect(skip.onPressed, isNull);
  });
}
