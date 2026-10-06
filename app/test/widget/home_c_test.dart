// 홈 구조 C: 앱바(남은 날) · 안내 한 줄 · 링 · '오늘 기록' 목록 하나 · 활동 한 줄.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/core/format.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/screens/p6_camera.dart';
import 'package:challory/ui/screens/p8_activity.dart';
import 'package:challory/ui/widgets/day_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

class _Steps extends ActivityNotifier {
  _Steps(this.steps);
  final int steps;
  @override
  TodayActivity build() => TodayActivity(stepsTotal: steps, stepsRecorded: steps);
}

/// 아침 건너뜀 · 점심 사과 170 확정 · 저녁 없음 · 간식 없음
List<MealRecord> _skippedBreakfast() => const [
      MealRecord(slot: MealSlot.breakfast, status: MealStatus.skipped, time: '20:31', serverId: 'm-skip'),
      MealRecord(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 170, aiKcal: 113, title: '사과', time: '11:36', serverId: 'm-apple'),
      MealRecord(slot: MealSlot.snack),
    ];

/// KST [hour]시(오늘 10.13)
DateTime Function() _kst(int hour) => () => DateTime.utc(2026, 10, 13, hour).subtract(const Duration(hours: 9));

Finder _notice() => find.byKey(const ValueKey('home-notice'));

Future<void> _openCamera(WidgetTester tester, String semantics) async {
  await tester.tap(find.bySemanticsLabel(semantics));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  tearDown(resetSession);

  group('안내 한 줄', () {
    testWidgets('검토 중이 섭취 적음 안내보다 먼저 · 한 줄만 · 뒤에 외 1건', (tester) async {
      await pumpApp(tester, overrides: [
        activityProvider.overrideWith(() => _Steps(reviewStepsCase)),
        mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast())),
        clockProvider.overrideWithValue(_kst(21)),
        noticesProvider.overrideWith(() => _NoNotices()),
      ]);
      expect(_notice(), findsOneWidget);
      expect(find.text('운동 기록을 확인 중이에요'), findsOneWidget);
      expect(find.text('소명하기'), findsOneWidget);
      expect(find.text('오늘 섭취 기록이 적어요'), findsNothing, reason: '한 줄만');
      expect(find.text('외 1건'), findsOneWidget);
      // 외 1건 → 다음 안내
      await tester.tap(find.text('외 1건'));
      await tester.pumpAndSettle();
      expect(_notice(), findsOneWidget);
      expect(find.text('오늘 섭취 기록이 적어요'), findsOneWidget);
      expect(find.text('운동 기록을 확인 중이에요'), findsNothing);
    });

    testWidgets('섭취 적음 안내: 정보 버튼을 누르면 기존 설명', (tester) async {
      await pumpApp(tester, overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast())),
        clockProvider.overrideWithValue(_kst(21)),
        noticesProvider.overrideWith(() => _NoNotices()),
      ]);
      expect(find.text('오늘 섭취 기록이 적어요'), findsOneWidget);
      expect(find.text('외 1건'), findsNothing);
      await tester.tap(find.byTooltip('섭취 안내 보기'));
      await tester.pumpAndSettle();
      expect(find.text('점수와 상관없이 충분히 드세요.\n이 안내는 순위와 점수에 영향을 주지 않아요.'), findsOneWidget);
    });

    testWidgets('보여 줄 안내가 없으면 줄이 없다', (tester) async {
      await pumpApp(tester, overrides: [noticesProvider.overrideWith(() => _NoNotices())]);
      expect(_notice(), findsNothing);
    });
  });

  group("'오늘 기록' 목록", () {
    testWidgets("머리글: 왼쪽 '오늘 기록', 오른쪽 '반영 n/4'", (tester) async {
      await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast()))]);
      expect(find.text('오늘 기록'), findsOneWidget);
      expect(find.text('반영 3/4'), findsOneWidget, reason: '아침(한도 안 건너뜀)·점심·걸음');
    });

    testWidgets("지난 날 머리글은 'M.D 기록'", (tester) async {
      final c = await pumpApp(tester);
      c.read(selectedDayProvider.notifier).set(7);
      await tester.pumpAndSettle();
      final d = curChallenge.start.add(const Duration(days: 6));
      expect(find.text('${d.month}.${d.day} 기록'), findsOneWidget);
      expect(find.text('오늘 기록'), findsNothing);
    });

    testWidgets('슬롯 순서대로 한 줄씩 · 줄 읽기 이름', (tester) async {
      await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast()))]);
      final rows = tester.widgetList<DayTimelineRow>(find.byType(DayTimelineRow)).toList();
      expect([for (final r in rows) r.meal.slot], [MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner, MealSlot.snack]);
      expect(find.bySemanticsLabel('점심 사과 170 kcal 확정, 열기'), findsOneWidget);
      expect(find.text('건너뜀'), findsOneWidget);
    });

    testWidgets("빈 끼니 칸: '기록 없음 · 대체 N' + '찍기'는 그 칸으로 촬영", (tester) async {
      final c = await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast()))]);
      final sub = c.read(todayResultProvider).intake.substituteFor(MealSlot.dinner);
      expect(find.text('기록 없음 · 대체 ${fmtM(sub)}'), findsOneWidget);
      expect(find.text('찍기'), findsOneWidget);
      await _openCamera(tester, '저녁 찍기');
      expect(tester.widget<CameraScreen>(find.byType(CameraScreen)).initialSlot, MealSlot.dinner);
    });

    testWidgets("빈 칸 대체값은 전날 같은 칸이 더 크면 그 값(819)", (tester) async {
      // 어제(D+7) 저녁 819 확정
      LedgerRow withDinner819(LedgerRow r) => LedgerRow(
            d: r.d, date: r.date, steps: r.steps, bmr: r.bmr, a: r.a, i: r.i, dd: r.dd, s: r.s, f: r.f, floorApplied: r.floorApplied,
            substituted: r.substituted, check: r.check, provisional: r.provisional, note: r.note, history: r.history, health: r.health,
            meals: [for (final m in r.meals) if (m.slot != MealSlot.dinner) m, const MealInput(slot: MealSlot.dinner, status: MealStatus.confirmed, kcal: 819)],
          );
      final c = await pumpApp(tester, overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast())),
        ledgerProvider.overrideWith((ref) async => [for (final r in mockLedger) r.d == 7 ? withDinner819(r) : r]),
      ]);
      expect(c.read(todayResultProvider).intake.substituteFor(MealSlot.dinner), 819);
      expect(find.text('기록 없음 · 대체 819'), findsOneWidget);
    });

    testWidgets("간식 칸: '찍은 만큼 더해져요' + '+ 추가'는 간식으로 촬영", (tester) async {
      await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast()))]);
      expect(find.text('찍은 만큼 더해져요'), findsOneWidget);
      await _openCamera(tester, '간식 추가');
      expect(tester.widget<CameraScreen>(find.byType(CameraScreen)).initialSlot, MealSlot.snack);
    });
  });

  testWidgets('활동 한 줄: 걸음 · 활동 kcal, 누르면 활동 탭', (tester) async {
    await pumpApp(tester);
    final row = find.byKey(const ValueKey('home-activity'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining('걸음 9,000')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining('kcal')), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(ActivityScreen), findsOneWidget);
  });

  group('앱바 · 챌린지 카드', () {
    testWidgets("챌린지 하나: 앱바에 'N일 남음' · 카드 없음 · 초대코드 참가는 남는다", (tester) async {
      final api = MockChalloryApi()..sessions.removeWhere((s) => s.monthly);
      await pumpApp(tester, overrides: [apiProvider.overrideWithValue(api)]);
      final ch = curChallenge;
      final left = ch.end.difference(ch.today).inDays;
      expect(find.text('D+${ch.dayIndex}/${ch.days} · $left일 남음'), findsOneWidget);
      expect(find.byKey(const ValueKey('challenge-card-0')), findsNothing);
      expect(find.text('초대코드로 참가'), findsOneWidget);
    });

    testWidgets('챌린지 여럿: 카드 목록 그대로 · 앱바는 D+ 만', (tester) async {
      await pumpApp(tester);
      expect(find.byKey(const ValueKey('challenge-card-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('challenge-card-1')), findsOneWidget);
      expect(find.text('D+8/28'), findsOneWidget);
      expect(find.textContaining('남음 ·'), findsNothing);
    });
  });

  testWidgets('360dp · 글자 1.3배에서 넘침 없음', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(tester, overrides: [
      activityProvider.overrideWith(() => _Steps(reviewStepsCase)),
      mealsProvider.overrideWith(() => MealsNotifier([
            ..._skippedBreakfast(),
            const MealRecord(slot: MealSlot.lunch, status: MealStatus.draft, aiKcal: 640, title: '김치찌개 백반 · 계란말이 · 김', time: '12:40', serverId: 'm-l2'),
            const MealRecord(slot: MealSlot.dinner, status: MealStatus.captured, time: '18:10', serverId: 'm-d1'),
          ])),
      clockProvider.overrideWithValue(_kst(21)),
    ]);
    tester.view.physicalSize = const Size(360, 2600);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _NoNotices extends NoticesNotifier {
  @override
  Future<List<Notice>> build() async => const [];
}
