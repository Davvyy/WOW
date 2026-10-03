// 홈: 한 슬롯의 끼니를 모두 한 줄씩 보여 주고, 누른 그 끼니의 P7 을 연다. P7: 서버 끼니는 지울 수 있다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
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
  _unknownKey();
  _checkboxes();
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

  testWidgets('P7 지우기: 확인 창 → 서버 지우기 → 홈 안내, 그 끼니만 사라진다', (tester) async {
    final api = MockChalloryApi();
    final container = await pumpApp(tester, location: R.meal(MealSlot.breakfast, meal: 'm-b2'), overrides: [
      apiProvider.overrideWithValue(api),
      mealsProvider.overrideWith(() => MealsNotifier(_twoBreakfasts())),
    ]);
    await tester.tap(find.byTooltip('기록 지우기'));
    await tester.pumpAndSettle();
    expect(find.text('이 기록을 지울까요?'), findsOneWidget);
    expect(find.text('사진과 음식 기록이 지워지고 점수가 다시 계산돼요. 되돌릴 수 없어요.'), findsOneWidget);
    // 취소하면 그대로
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(api.deletedMeals, isEmpty);
    expect(find.text('아침 확인'), findsOneWidget);

    await tester.tap(find.byTooltip('기록 지우기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pumpAndSettle();
    expect(api.deletedMeals, ['m-b2']);
    expect(find.text('기록을 지웠어요'), findsOneWidget);
    expect(find.text('D+8/28'), findsOneWidget, reason: '홈으로 돌아옴');
    final breakfasts = mealsIn(container.read(mealsProvider), MealSlot.breakfast);
    expect([for (final m in breakfasts) m.title], ['계란토스트 · 바나나']);
    expect(_rowsOf(MealSlot.breakfast), findsOneWidget);
  });

  testWidgets('P7 지우기를 서버가 거절하면 끼니를 되돌리고 그 문구를 보여 준다', (tester) async {
    final api = MockChalloryApi()..failNext = const ApiException(422, '판정된 기록은 지울 수 없어요');
    final container = await pumpApp(tester, location: R.meal(MealSlot.breakfast, meal: 'm-b2'), overrides: [
      apiProvider.overrideWithValue(api),
      mealsProvider.overrideWith(() => MealsNotifier(_twoBreakfasts())),
    ]);
    await tester.tap(find.byTooltip('기록 지우기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pumpAndSettle();
    expect(find.text('판정된 기록은 지울 수 없어요'), findsOneWidget);
    expect(mealsIn(container.read(mealsProvider), MealSlot.breakfast), hasLength(2));
    expect(_rowsOf(MealSlot.breakfast), findsNWidgets(2));
  });

  testWidgets('서버 id 가 없는 끼니(모의 시드)·새 기록은 지우기 버튼이 없다', (tester) async {
    await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'mock-lunch'), overrides: [mealsProvider.overrideWith(() => MealsNotifier(_twoBreakfasts()))]);
    expect(find.text('점심 확인'), findsOneWidget);
    expect(find.byTooltip('기록 지우기'), findsNothing);
  });

  testWidgets('끼니가 있는 슬롯의 P7 은 건너뜀을 끈다(건너뜀은 빈 슬롯에서만)', (tester) async {
    await pumpApp(tester, location: R.meal(MealSlot.breakfast, meal: 'm-b2'), overrides: [mealsProvider.overrideWith(() => MealsNotifier(_twoBreakfasts()))]);
    final skip = tester.widget<ChButton>(find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith('건너뜀')));
    expect(skip.onPressed, isNull);
  });
}

void _unknownKey() {
  testWidgets('P7 을 없는 끼니 키로 열면 예시 항목 없이 홈으로 돌아가 안내', (tester) async {
    await pumpApp(tester, location: R.meal(MealSlot.lunch, meal: 'gone-1'), overrides: [mealsProvider.overrideWith(() => MealsNotifier(_twoBreakfasts()))]);
    expect(find.text('기록을 찾지 못했어요'), findsOneWidget);
    expect(find.text('D+8/28'), findsOneWidget, reason: '홈');
    expect(find.text('점심 확인'), findsNothing);
    expect(find.textContaining('확정 · 약'), findsNothing);
  });
}

/// 확정 요청에 실린 항목을 남긴다
class _ConfirmSpy extends MockChalloryApi {
  List<Map<String, dynamic>>? sent;
  @override
  Future<ConfirmResult> confirmMeal(String mealId, int version, List<Map<String, dynamic>> items, {required String idempotencyKey}) async {
    sent = items;
    return ConfirmResult(mealId: mealId, confirmedKcal: wireTotal(items), version: version + 1);
  }
}

/// 기본 시드 + 아침에 항목 3개짜리 확정 끼니(시리얼 162 · 우유 130 · 바나나 100)
List<MealRecord> _threeItemBreakfast() => [
      ...buildTodayMeals(),
      const MealRecord(
        slot: MealSlot.breakfast,
        status: MealStatus.confirmed,
        kcal: 392,
        title: '시리얼 · 우유',
        time: '06:38',
        serverId: 'm-c3',
        version: 2,
        items: [
          MealItem(id: 'a', candidates: ['시리얼', '과자'], candKcal: [162, 300], portion: '1인분', kind: ItemKind.side),
          MealItem(id: 'b', candidates: ['우유'], candKcal: [130], portion: '1잔', kind: ItemKind.side),
          MealItem(id: 'c', candidates: ['바나나'], candKcal: [100], portion: '1개', kind: ItemKind.side),
        ],
      ),
    ];

Finder _check(String name) => find.byWidgetPredicate((w) => w is ChCheck && w.label == '$name 먹었어요');
Finder _confirmButton() => find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith('확정'));

void _checkboxes() {
  group('P7 체크박스', () {
    testWidgets('여러 항목 중 일부만 체크하면 그 항목만 합계·서버 전송에 들어가고 체크 상태가 남는다', (tester) async {
      final api = _ConfirmSpy();
      final c = await pumpApp(tester, location: R.meal(MealSlot.breakfast, meal: 'm-c3'), overrides: [
        apiProvider.overrideWithValue(api),
        mealsProvider.overrideWith(() => MealsNotifier(_threeItemBreakfast())),
      ]);
      expect(find.textContaining('확정 · 약 392 kcal'), findsOneWidget);
      await tester.tap(_check('우유'));
      await tester.pumpAndSettle();
      expect(find.textContaining('확정 · 약 262 kcal'), findsOneWidget);
      await tester.tap(_confirmButton());
      await tester.pumpAndSettle();

      expect([for (final i in api.sent!) i['eaten']], [true, false, true]);
      expect(wireTotal(api.sent!), 262);
      final saved = c.read(mealsProvider).firstWhere((m) => m.serverId == 'm-c3');
      expect(saved.kcal, 262);
      expect([for (final i in saved.items) i.checked], [true, false, true]);
    });

    testWidgets('체크를 모두 풀면 확정 버튼이 꺼지고 안내가 나오며 서버에 보내지 않는다', (tester) async {
      final api = _ConfirmSpy();
      await pumpApp(tester, location: R.meal(MealSlot.breakfast, meal: 'm-c3'), overrides: [
        apiProvider.overrideWithValue(api),
        mealsProvider.overrideWith(() => MealsNotifier(_threeItemBreakfast())),
      ]);
      for (final n in ['시리얼', '우유', '바나나']) {
        await tester.tap(_check(n));
        await tester.pumpAndSettle();
      }
      expect(tester.widget<ChButton>(_confirmButton()).onPressed, isNull);
      expect(find.textContaining('체크한 음식이 없어요'), findsOneWidget);
      await tester.tap(_confirmButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(api.sent, isNull);
      expect(find.text('아침 확인'), findsOneWidget, reason: '화면에 그대로 남는다');
    });
  });
}
