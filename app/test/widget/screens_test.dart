import 'package:challory/core/engine/engine.dart';
import 'package:challory/core/format.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/state/session.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/screens/p11_rules.dart';
import 'package:challory/ui/screens/p9_leaderboard.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:challory/ui/widgets/ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

Future<ProviderContainer> pumpApp(WidgetTester tester, {String location = R.home, List<Override> overrides = const []}) async {
  tester.view.physicalSize = const Size(420, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
}

Future<void> pumpWidgetScreen(WidgetTester tester, Widget screen, {List<Override> overrides = const []}) async {
  tester.view.physicalSize = const Size(420, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(overrides: overrides, child: MaterialApp(theme: buildTheme(Brightness.light), home: screen)));
  await tester.pumpAndSettle();
}

/// 스낵바 타이머(2.2초)를 흘려보내 닫는다.
Future<void> dismissSnack(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400)); // 등장 애니메이션 끝 → 타이머 시작
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  group('mock 데이터 = 엔진 계산', () {
    test('지수 BMR 1,650 · 오늘 28.8점 · 누적 312.6', () {
      expect(mockMe.bmr, 1650);
      final today = engine.simulate(SimulateInput(profile: mockMe.profile, stepsTotal: 9000, meals: buildTodayMeals().map((m) => m.toInput()).toList()));
      expect(today.score.sD, 28.8);
      expect(today.score.dD, 144);
      expect(today.intake.iD, 1800);
      expect(mockCumulative, 312.6);
      expect(mockLeaderboard.cumulative[2].score! - mockCumulative, closeTo(76.1, 0.001));
    });

    test('정정된 10.12: 41.2 → 12.7', () {
      final r = mockLedger[6];
      expect(r.sBefore, 41.2);
      expect(r.s, 12.7);
    });
  });

  group('P5 홈', () {
    testWidgets('링·숫자 셋·점수·반영률·슬롯 4개를 엔진 값으로 렌더', (tester) async {
      await pumpApp(tester);
      expect(find.text('D+8/28'), findsOneWidget);
      expect(find.textContaining('−144'), findsOneWidget); // 링 중앙 −144 kcal
      expect(find.textContaining('목표 −500의 29%'), findsOneWidget);
      expect(find.textContaining('약 1,944'), findsOneWidget); // 소비
      expect(find.textContaining('1,800'), findsWidgets); // 섭취
      expect(find.textContaining('28.8'), findsWidgets); // 점수
      expect(find.textContaining('312.6'), findsOneWidget); // 누적
      expect(find.textContaining('잠정 4위'), findsOneWidget);
      expect(find.text('점수 계산 보기'), findsWidgets);
      expect(find.textContaining('반영률 100%'), findsOneWidget);
      for (final s in ['아침', '점심', '저녁', '간식']) {
        expect(find.text(s), findsWidgets);
      }
      expect(find.text('식사 촬영'), findsNothing); // 시맨틱 라벨은 텍스트가 아님
      expect(find.byIcon(Icons.photo_camera_rounded), findsOneWidget); // 촬영 FAB
    });

    testWidgets('날짜 스와이프로 이전 날(10.12 정정) 표시', (tester) async {
      await pumpApp(tester);
      await tester.fling(find.byType(CalorieRing), const Offset(300, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.text('D+7/28'), findsOneWidget);
      expect(find.textContaining('저녁 무효'), findsWidgets);
    });

    testWidgets('점심 초안 상태에서는 잠정 1,105 캡션', (tester) async {
      await pumpApp(tester, overrides: [mealsProvider.overrideWith(() => MealsNotifier(buildLunchDraftMeals()))]);
      expect(find.textContaining('점심 미확정 → 1,105 kcal로 잠정 계산 중'), findsOneWidget);
    });
  });

  group('P7 식사 확인·편집', () {
    testWidgets('김 해제 시 합계 850 → 780, 확정하면 P5가 엔진으로 28.8 재계산', (tester) async {
      final container = await pumpApp(tester, location: R.meal(MealSlot.lunch), overrides: [mealsProvider.overrideWith(() => MealsNotifier(buildLunchDraftMeals()))]);
      expect(find.textContaining('약 850'), findsWidgets);
      expect(find.textContaining('AI 초안 약 850'), findsOneWidget);
      // 김(6번째 항목) 체크 해제
      await tester.tap(find.byType(ChCheck).at(5));
      await tester.pumpAndSettle();
      expect(find.textContaining('780'), findsWidgets);
      expect(find.textContaining('AI 초안 약 850'), findsOneWidget);
      expect(find.textContaining('1개 먹지 않음'), findsOneWidget);

      await tester.tap(find.textContaining('확정 · 약 780'));
      await tester.pumpAndSettle();
      final lunch = container.read(mealsProvider).firstWhere((m) => m.slot == MealSlot.lunch);
      expect(lunch.status, MealStatus.confirmed);
      expect(lunch.kcal, 780);
      // 홈으로 복귀, 엔진 재계산
      expect(find.text('D+8/28'), findsOneWidget);
      expect(container.read(todayResultProvider).score.sD, 28.8);
      expect(find.textContaining('28.8'), findsWidgets);
    });

    testWidgets('후보 칩은 이름과 kcal을 함께 바꾼다 · 국물 −40%', (tester) async {
      await pumpApp(tester, location: R.meal(MealSlot.lunch), overrides: [mealsProvider.overrideWith(() => MealsNotifier(buildLunchDraftMeals()))]);
      // 흰쌀밥 → 현미밥(300): 합계 850 − 10 = 840
      await tester.tap(find.textContaining('현미밥').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('약 840'), findsWidgets);
      // 국물 안 먹음: 김치찌개 260 → 156
      await tester.tap(find.byType(ChSwitch).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('약 736'), findsWidgets);
    });

    testWidgets('AI 대비 50% 넘게 낮추면 확인 모달', (tester) async {
      await pumpApp(tester, location: R.meal(MealSlot.lunch), overrides: [mealsProvider.overrideWith(() => MealsNotifier(buildLunchDraftMeals()))]);
      await tester.tap(find.byType(ChCheck).at(1)); // 김치찌개 해제
      await tester.tap(find.byType(ChCheck).at(2)); // 계란말이 해제
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('확정 · 약'));
      await tester.pumpAndSettle();
      expect(find.text('AI 추정보다 50% 넘게 낮아요'), findsOneWidget);
      await tester.tap(find.text('다시 볼게요'));
      await tester.pumpAndSettle();
      expect(find.text('AI 추정보다 50% 넘게 낮아요'), findsNothing);
    });
  });

  group('P9 리더보드', () {
    testWidgets('오늘/누적, 포디움, 내 행, 격차, 집계 중, 하트 1일 1회', (tester) async {
      await pumpWidgetScreen(tester, const LeaderboardScreen());
      expect(find.text('오늘 (잠정)'), findsOneWidget);
      expect(find.text('누적'), findsOneWidget);
      expect(find.textContaining('잠정 · 매시간 갱신'), findsOneWidget);
      expect(find.textContaining('지수(나)'), findsOneWidget);
      expect(find.textContaining('위 순위까지 3.2점'), findsOneWidget);
      expect(find.text('집계 중'), findsOneWidget);
      expect(find.text('워치'), findsOneWidget); // 달려라하니(4위)

      await tester.tap(find.text('누적'));
      await tester.pumpAndSettle();
      expect(find.textContaining('확정 · 10.13 09:00'), findsOneWidget);
      expect(find.textContaining('3위까지 76.1점'), findsOneWidget);
      expect(find.text('공동'), findsNWidgets(2));
      expect(find.text('집계 중'), findsOneWidget);

      // 응원 하트: 첫 번째는 성공, 두 번째는 "내일 다시"
      await tester.tap(find.byTooltip('오이냉국 응원하기'));
      await tester.pump();
      expect(find.text('응원했어요(오늘 1회)'), findsOneWidget);
      await dismissSnack(tester);
      await tester.tap(find.byTooltip('새벽러닝 응원하기 (오늘 응원을 이미 보냈어요)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('내일 다시 응원할 수 있어요'), findsOneWidget);
      await dismissSnack(tester);
    });

    testWidgets('신고 시트', (tester) async {
      await pumpWidgetScreen(tester, const LeaderboardScreen());
      await tester.tap(find.byTooltip('더보기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('익명으로 신고'));
      await tester.pumpAndSettle();
      expect(find.text('사진 재사용'), findsOneWidget);
      await tester.tap(find.text('신고하기'));
      await tester.pump();
      expect(find.text('신고했어요. 운영자가 확인해요'), findsOneWidget);
      await dismissSnack(tester);
    });
  });

  group('P11 규칙 시뮬레이터', () {
    testWidgets('기본 입력 9,000 / 0 / 1,800 → 28.8점, 상수는 EngineRules에서', (tester) async {
      await pumpWidgetScreen(tester, const RulesScreen());
      expect(find.textContaining('28.8'), findsOneWidget);
      expect(find.textContaining('BMR 1,650 기준'), findsOneWidget);
      expect(find.text('T 500'), findsOneWidget);
      expect(find.text('활동 상한 1,000'), findsOneWidget);
      expect(find.text('섭취 하한 max(1,200, 0.8×BMR)'), findsOneWidget);
      expect(find.text('대체값 max(700, 0.45×BMR)'), findsOneWidget);
      expect(find.textContaining('① '), findsNothing);
    });

    testWidgets('입력을 바꾸면 ScoreSimulator 결과가 즉시 바뀐다', (tester) async {
      await pumpWidgetScreen(tester, const RulesScreen());
      await tester.enterText(find.byType(TextField).at(1), '30'); // 달리기 30분
      await tester.pumpAndSettle();
      final expected = engine
          .simulate(const SimulateInput(
            profile: Profile(sex: Sex.m, weightKg: 70, heightCm: 175, age: 30),
            stepsTotal: 9000,
            sessions: [SessionInput(type: SessionType.running, minutes: 30, distanceM: 4500, stepsInRange: 4500)],
            meals: [
              MealInput(slot: MealSlot.breakfast, status: MealStatus.confirmed, kcal: 600),
              MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 600),
              MealInput(slot: MealSlot.dinner, status: MealStatus.confirmed, kcal: 600),
            ],
          ))
          .score
          .sD;
      expect(expected, greaterThan(28.8));
      expect(find.textContaining(fmtK1(expected)), findsOneWidget);
    });
  });

  group('월간·동시 참가 설명·설정', () {
    testWidgets('P11: 새 순위 규칙과 점검 기간·나가기 설명', (tester) async {
      await pumpApp(tester, location: R.rules);
      expect(find.textContaining('일평균 × (1 + 참여율)'), findsOneWidget);
      expect(find.textContaining('참가한 날부터 3일은 점검 기간'), findsOneWidget);
      expect(find.textContaining('나가면 순위에서 빠지고 기록은 보관돼요'), findsOneWidget);
    });

    testWidgets('P12: 다음 달 자동 참가 토글', (tester) async {
      final api = MockChalloryApi();
      await pumpApp(tester, location: R.settings, overrides: [apiProvider.overrideWithValue(api)]);
      expect(find.text('다음 달 챌린지 자동 참가'), findsOneWidget);
      await tester.tap(find.byWidgetPredicate((w) => w is ChSwitch && w.label == '다음 달 챌린지 자동 참가'));
      await tester.pumpAndSettle();
      expect(await api.fetchAutoContinue(), isFalse);
    });
  });

  testWidgets('P1 로고는 앱 아이콘과 같은 C 링 + 불꽃 마크를 테마 색으로 그린다', (tester) async {
    await pumpApp(tester, location: R.p1);
    final logo = tester.widget<Image>(find.byWidgetPredicate(
        (w) => w is Image && w.image is AssetImage && (w.image as AssetImage).assetName == 'assets/icon/app_icon_monochrome.png'));
    expect(logo.color, Colors.white); // 라이트 테마 onBrand
    expect(find.byIcon(Icons.local_fire_department_rounded), findsNothing);
  });

  testWidgets('P1: 이번 달 챌린지 참가하기 버튼이 먼저, 초대코드 입력란은 눌러야 보인다', (tester) async {
    await pumpApp(tester, location: R.p1);
    expect(find.text('이번 달 챌린지 참가하기'), findsOneWidget);
    expect(find.bySemanticsLabel('초대코드 6자리'), findsNothing);
    await tester.tap(find.text('초대코드가 있어요'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('초대코드 6자리'), findsOneWidget);
  });
}
