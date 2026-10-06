// 홈 표시: 숫자 셋 한 줄 정렬 · 반영 n/4 와 건너뜀 줄 · 검토 중 안내는 안내 줄 하나 · 챌린지 하나면 카드 없음 ·
// 섭취 적음 안내는 저녁 기록 뒤나 21시부터.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/core/format.dart';
import 'package:challory/ui/widgets/challenge_cards.dart';
import 'package:challory/ui/widgets/day_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp, pumpWidgetScreen;

class _Skips extends SkipsNotifier {
  _Skips(this.used);
  final int used;
  @override
  int build() => used;
}

class _Steps extends ActivityNotifier {
  _Steps(this.steps);
  final int steps;
  @override
  TodayActivity build() => TodayActivity(stepsTotal: steps, stepsRecorded: steps);
}

/// 아침 건너뜀 · 점심 사과 170 확정 · 저녁 없음
List<MealRecord> _skippedBreakfast() => const [
      MealRecord(slot: MealSlot.breakfast, status: MealStatus.skipped, time: '20:31', serverId: 'm-skip'),
      MealRecord(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 170, aiKcal: 113, title: '사과', time: '11:36', serverId: 'm-apple'),
      MealRecord(slot: MealSlot.snack),
    ];

/// KST [hour]시(오늘 10.13)
DateTime Function() _kst(int hour) => () => DateTime.utc(2026, 10, 13, hour).subtract(const Duration(hours: 9));

void main() {
  tearDown(resetSession);

  group('A5 숫자 셋', () {
    for (final width in [360.0, 411.0]) {
      testWidgets('${width.toInt()}dp: 소비·섭취·점수 값이 한 줄로 같은 높이에 놓인다', (tester) async {
        await pumpApp(tester);
        tester.view.physicalSize = Size(width, 2600);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final rects = [for (final k in ['소비', '섭취', '점수']) tester.getRect(find.byKey(ValueKey('home-stat-$k')))];
        for (final r in rects.skip(1)) {
          expect((r.top - rects.first.top).abs(), lessThanOrEqualTo(1), reason: '$rects');
          expect((r.height - rects.first.height).abs(), lessThanOrEqualTo(1), reason: '한 줄 · $rects');
        }
        expect(find.textContaining('약'), findsWidgets);
      });
    }
  });

  group('A7 반영 n/4 · 건너뜀 줄', () {
    testWidgets('한도 안의 건너뜀은 "건너뜀"으로 보이고 반영된 칸으로 센다', (tester) async {
      await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast()))]);
      expect(find.text('건너뜀'), findsOneWidget);
      expect(find.bySemanticsLabel('아침 건너뜀 0 kcal 20:31에 건너뛰었어요, 열기'), findsOneWidget);
      expect(find.text('반영 3/4'), findsOneWidget, reason: '아침(건너뜀)·점심·걸음');
      expect(find.bySemanticsLabel(RegExp('아침 건너뜀, 점심 확정')), findsOneWidget, reason: '머리글 읽기 이름');
    });

    testWidgets('한도를 넘은 건너뜀은 대체값이 들어가 반영된 칸으로 세지 않는다', (tester) async {
      final c = await pumpApp(tester, overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast())),
        skipsUsedProvider.overrideWith(() => _Skips(3)),
      ]);
      expect(find.text('건너뜀'), findsOneWidget);
      final sub = c.read(todayResultProvider).intake.substituteFor(MealSlot.breakfast);
      expect(find.text('한도를 넘어 대체 ${fmtM(sub)} 적용'), findsOneWidget);
      expect(find.text('반영 2/4'), findsOneWidget);
      final row = tester.widget<DayTimelineRow>(find.byWidgetPredicate((w) => w is DayTimelineRow && w.meal.slot == MealSlot.breakfast));
      expect(row.overLimitSkip, isTrue);
    });
  });

  testWidgets('B1 검토 중: 위 안내 줄만 설명하고 링 칩·활동 줄은 짧은 표시', (tester) async {
    await pumpApp(tester, overrides: [activityProvider.overrideWith(() => _Steps(reviewStepsCase))]);
    expect(find.text('운동 기록을 확인 중이에요'), findsOneWidget, reason: '위 안내 줄 한 곳');
    expect(find.bySemanticsLabel(RegExp('평소의 2.5배를 넘어 검토 중이에요')), findsOneWidget, reason: '자세한 문장은 읽기 이름에');
    expect(find.text('소명하기'), findsOneWidget);
    expect(find.text('검토 중 · 잠정 유지'), findsNothing);
    expect(find.text('검토 중'), findsOneWidget, reason: '링 아래 칩');
    expect(find.textContaining('걸음이 검토 중'), findsNothing);
    expect(find.byTooltip('검토 중'), findsOneWidget, reason: '활동 줄 걸음 옆 방패');
    expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == '검토 중'), findsOneWidget, reason: '방패 아이콘의 읽기 이름');
  });

  group('B2 챌린지 카드', () {
    testWidgets('하나뿐이면 카드 없이 링크만(남은 날은 앱바)', (tester) async {
      final api = MockChalloryApi()..sessions.removeWhere((s) => !s.monthly);
      await pumpWidgetScreen(tester, const Scaffold(body: ChallengeCards()), overrides: [apiProvider.overrideWithValue(api)]);
      final ch = api.sessions.single.challenge;
      expect(find.byKey(const ValueKey('challenge-card-0')), findsNothing);
      expect(find.text('월간'), findsNothing);
      expect(find.text(ch.name), findsNothing);
      expect(find.textContaining('일 남음'), findsNothing);
      expect(find.text('초대코드로 참가'), findsOneWidget);
      expect(ChallengeCards.leftText(ch), '${ch.end.difference(ch.today).inDays}일 남음');
    });

    testWidgets('여러 개면 이름을 보이고 카운터는 N일 남음', (tester) async {
      final api = MockChalloryApi();
      await pumpWidgetScreen(tester, const Scaffold(body: ChallengeCards()), overrides: [apiProvider.overrideWithValue(api)]);
      for (final s in api.sessions) {
        expect(find.text(s.challenge.name), findsOneWidget);
      }
      expect(find.textContaining('일 남음'), findsNWidgets(2));
      expect(find.textContaining('D-'), findsNothing);
    });
  });

  group('B4 섭취 적음 안내', () {
    testWidgets('오늘 저녁 전 낮에는 보이지 않는다', (tester) async {
      await pumpApp(tester, overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast())),
        clockProvider.overrideWithValue(_kst(14)),
      ]);
      expect(find.text('오늘 섭취 기록이 적어요'), findsNothing);
    });

    testWidgets('21시가 지나면 보인다(두 문장 안내)', (tester) async {
      await pumpApp(tester, overrides: [
        mealsProvider.overrideWith(() => MealsNotifier(_skippedBreakfast())),
        clockProvider.overrideWithValue(_kst(21)),
      ]);
      expect(find.text('오늘 섭취 기록이 적어요'), findsOneWidget);
      await tester.tap(find.byTooltip('섭취 안내 보기'));
      await tester.pumpAndSettle();
      expect(find.text('점수와 상관없이 충분히 드세요.\n이 안내는 순위와 점수에 영향을 주지 않아요.'), findsOneWidget);
    });

    testWidgets('저녁을 기록했으면 낮에도 보인다', (tester) async {
      await pumpApp(tester, overrides: [
        mealsProvider.overrideWith(() => MealsNotifier([
              ..._skippedBreakfast(),
              const MealRecord(slot: MealSlot.dinner, status: MealStatus.confirmed, kcal: 300, title: '샐러드', time: '17:10', serverId: 'm-dinner'),
            ])),
        clockProvider.overrideWithValue(_kst(17)),
      ]);
      expect(find.text('오늘 섭취 기록이 적어요'), findsOneWidget);
    });
  });
}
