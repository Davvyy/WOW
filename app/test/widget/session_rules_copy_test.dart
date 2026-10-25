// 규칙 값을 말하는 문구는 지금 챌린지 규칙(engine.rules · currentSession)을 따른다.
// 기본값(T 500 · C 1,000 · 간식 150 · 점검 3일 · 09:00 · 48시간 · 72시간 · 2.5배)이 아닌 규칙으로 화면을 그려 그 값이 보이는지 본다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/core/format.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/challenge_cards.dart';
import 'package:challory/ui/widgets/ring.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

const _rules = EngineRules(t: 400, c: 800, snackKcal: 120, checkDays: 2, autoConfirm: 1.5);

ChallengeSession _session({String status = 'running', DateTime? checkStart}) => ChallengeSession(
      challenge: mockChallenge,
      me: mockMe,
      rules: _rules,
      status: status,
      challengeId: 'mock-challenge',
      participantId: 'mock-p',
      checkStart: checkStart ?? DateTime(2026, 10, 6),
      finalizeTime: '08:30',
      editWindowHours: 36,
      appealHours: 60,
      stepsSpikeRatio: 3,
    );

class _Api extends MockChalloryApi {
  _Api(ChallengeSession s) {
    sessions[0] = s;
  }
}

class _Steps extends ActivityNotifier {
  _Steps(this.steps);
  final int steps;
  @override
  TodayActivity build() => TodayActivity(stepsTotal: steps, stepsRecorded: steps);
}

/// 규칙을 바꾼 챌린지로 화면을 연다(셸 밖 화면도 같은 규칙을 읽도록 세션도 바로 적용)
Future<void> _pump(WidgetTester tester, {String location = R.home, ChallengeSession? session, List<Object> extra = const []}) async {
  final s = session ?? _session();
  applySession(s);
  await pumpApp(tester, location: location, overrides: [apiProvider.overrideWithValue(_Api(s)), ...extra.cast()]);
}

void main() {
  tearDown(resetSession);

  test('fmtRatio: 끝의 0은 뺀다', () {
    expect([fmtRatio(2.5), fmtRatio(3), fmtRatio(1.3), fmtRatio(1.25)], ['2.5', '3', '1.3', '1.25']);
  });

  test('검토 안내 문구의 소명 시간은 규칙 값', () {
    final t = reviewBannerText(remote: true, review: const MyReview(id: 'r', type: 'source_unknown', status: 'open'), appealHours: 60);
    expect(t.rest, '. 60시간 안에 설명을 남길 수 있어요.');
  });

  test('점검 기간 상태 줄은 규칙의 점검 일수', () {
    final s = _session(checkStart: DateTime(2026, 10, 12));
    expect(ChallengeCards.statusLine(s, DateTime(2026, 10, 12)), '점검 기간 1/2일');
    expect(ChallengeCards.statusLine(s, DateTime(2026, 10, 13)), '점검 기간 2/2일');
    expect(ChallengeCards.statusLine(s, DateTime(2026, 10, 14)), isNot(contains('점검 기간')));
  });

  testWidgets('홈 링: 목표 표시는 −T', (tester) async {
    await _pump(tester);
    expect(tester.widget<CalorieRing>(find.byType(CalorieRing)).targetLabel, '−400');
    expect(find.text('−400'), findsOneWidget);
    expect(find.text('−500'), findsNothing);
  });

  testWidgets('홈 걸음 급증 안내: 배율·소명 시간은 규칙 값', (tester) async {
    await _pump(tester, extra: [activityProvider.overrideWith(() => _Steps(reviewStepsCase))]);
    expect(find.bySemanticsLabel(RegExp('평소의 3배를 넘어 검토 중이에요.*60시간 안에 설명을 남길 수 있어요')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('2.5배|72시간')), findsNothing);
  });

  testWidgets('홈 모집 중: 첫 N일 점검 기간', (tester) async {
    await _pump(tester, session: _session(status: 'recruiting'));
    expect(find.textContaining('첫 2일은 점검 기간'), findsOneWidget);
    expect(find.textContaining('첫 3일'), findsNothing);
  });

  testWidgets('홈 최종 집계 중: 확정 시각은 규칙 값', (tester) async {
    await _pump(tester, session: _session(status: 'closing'));
    expect(find.textContaining('${fmtMd(mockChallenge.end.add(const Duration(days: 1)))} 08:30에 확정됐어요'), findsOneWidget);
    expect(find.textContaining('09:00'), findsNothing);
  });

  testWidgets('활동: 그래프 상한 · 걸음 급증 배율', (tester) async {
    await _pump(tester, location: R.activity, extra: [activityProvider.overrideWith(() => _Steps(reviewStepsCase))]);
    expect(find.text('추정 · 상한 800'), findsOneWidget);
    expect(find.textContaining('상한 1,000'), findsNothing);
    expect(find.textContaining('평소 중앙값의 3배를 넘어'), findsOneWidget);
  });

  testWidgets('순위: 잠정 안내·빈 화면 안내의 확정 시각', (tester) async {
    await _pump(tester, location: R.rank);
    expect(find.text('잠정 순위예요. 매시간 바뀌고 내일 08:30에 확정돼요.'), findsOneWidget);
    expect(find.textContaining('09:00'), findsNothing);
  });

  testWidgets('순위 모집 중: 첫 N일(점검 기간)', (tester) async {
    await _pump(tester, location: R.rank, session: _session(status: 'recruiting'));
    expect(find.textContaining('첫 2일(점검 기간)'), findsOneWidget);
  });

  testWidgets('순위 최종 집계 중: 확정 시각', (tester) async {
    await _pump(tester, location: R.rank, session: _session(status: 'closing'));
    expect(find.textContaining('${fmtMd(mockChallenge.end.add(const Duration(days: 1)))} 08:30 확정'), findsOneWidget);
  });

  testWidgets('규칙: 참가한 날부터 N일은 점검 기간', (tester) async {
    await _pump(tester, location: R.rules);
    expect(find.textContaining('참가한 날부터 2일은 점검 기간'), findsOneWidget);
    expect(find.textContaining('3일은 점검 기간'), findsNothing);
  });

  testWidgets('점수 장부: 확정 시각', (tester) async {
    await _pump(tester, location: R.ledger);
    expect(find.textContaining('다음 날 08:30에 확정돼요'), findsOneWidget);
    expect(find.textContaining('09:00'), findsNothing);
  });

  group('식사 확인', () {
    List<MealRecord> smallDinner() => [
          for (final m in buildTodayMeals()) if (m.slot != MealSlot.dinner) m,
          const MealRecord(
            slot: MealSlot.dinner,
            status: MealStatus.confirmed,
            kcal: 100,
            title: '바나나',
            time: '19:14',
            serverId: 'm-banana',
            version: 2,
            items: [MealItem(id: 'b', candidates: ['바나나'], candKcal: [100], portion: '1개', kind: ItemKind.side)],
          ),
        ];

    testWidgets('간식 기준 · 확정 시각 · 수정 기한 · 자동 확정 배율', (tester) async {
      await _pump(tester, location: R.meal(MealSlot.dinner, meal: 'm-banana'), extra: [mealsProvider.overrideWith(() => MealsNotifier(smallDinner()))]);
      expect(find.textContaining('120 kcal 미만은 간식이에요'), findsOneWidget);
      expect(find.textContaining('08:30까지 확정하지 않으면'), findsOneWidget);
      expect(find.textContaining('1.5×AI'), findsOneWidget);
      expect(find.textContaining('그 뒤 36시간 안에는 고칠 수 있어요'), findsOneWidget);
      for (final old in ['150 kcal', '09:00', '48시간', '1.3×AI']) {
        expect(find.textContaining(old), findsNothing, reason: old);
      }
    });

    testWidgets('자동 확정 끼니 안내 · 수정 기한', (tester) async {
      final meals = [
        for (final s in MealSlot.values)
          s == MealSlot.lunch
              ? MealRecord(slot: s, status: MealStatus.auto, kcal: 900, aiKcal: 200, time: '09:00', title: '자동 확정', items: mockDraftItems(s))
              : MealRecord(slot: s),
      ];
      await _pump(tester, location: R.meal(MealSlot.lunch, meal: 'mock-lunch'), extra: [mealsProvider.overrideWith(() => MealsNotifier(meals))]);
      expect(find.textContaining('08:30까지 확정하지 않아'), findsOneWidget);
      expect(find.textContaining('확정값으로 바뀌어요(36시간 안)'), findsOneWidget);
      expect(find.textContaining('1.5×AI 200'), findsOneWidget);
    });
  });

  testWidgets('P1: 없는 카카오톡 링크 자동 채움을 말하지 않는다', (tester) async {
    await pumpApp(tester, location: R.p1);
    await tester.tap(find.text('초대코드가 있어요'));
    await tester.pumpAndSettle();
    expect(find.textContaining('카카오톡 링크'), findsNothing);
    expect(find.textContaining('자동으로 채워져요'), findsNothing);
  });
}
