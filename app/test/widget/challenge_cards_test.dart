// 홈 챌린지 카드: 참가 목록·선택·공유 안내·이번 달 참가·동시 3개
import 'dart:async';

import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/challenge_cards.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp, pumpWidgetScreen;

void main() {
  tearDown(resetSession);

  testWidgets('참가 중인 챌린지 카드 2장 · 공유 안내 · 누르면 선택', (tester) async {
    final api = MockChalloryApi();
    await pumpWidgetScreen(tester, const Scaffold(body: ChallengeCards()), overrides: [apiProvider.overrideWithValue(api)]);
    expect(find.text('10월 챌린지'), findsOneWidget);
    expect(find.text('가을 걷기 챌린지'), findsOneWidget);
    expect(find.text('월간'), findsOneWidget);
    expect(find.textContaining('순위 점수 82.6점'), findsOneWidget);
    expect(find.text('기록은 참가 중인 2개 챌린지에 함께 반영돼요'), findsOneWidget);
    await tester.tap(find.text('10월 챌린지'));
    await tester.pumpAndSettle();
    expect(curChallenge.name, '10월 챌린지');
  });

  testWidgets('이번 달 챌린지에 참가: 체중 확인 시트 → 참가', (tester) async {
    final api = MockChalloryApi()..sessions.removeWhere((s) => s.monthly);
    await pumpWidgetScreen(tester, const Scaffold(body: ChallengeCards()), overrides: [apiProvider.overrideWithValue(api)]);
    expect(find.text('기록은 참가 중인 2개 챌린지에 함께 반영돼요'), findsNothing);
    await tester.tap(find.text('이번 달 챌린지 참가하기'));
    await tester.pumpAndSettle();
    expect(find.text('10월 챌린지 참가'), findsOneWidget);
    expect(find.textContaining('3일은 점검 기간'), findsOneWidget);
    await tester.tap(find.text('참가하기'));
    await tester.pumpAndSettle();
    expect(api.lastJoin!.challengeId, 'mock-monthly');
    expect(find.text('10월 챌린지에 참가했어요'), findsOneWidget);
    expect(find.text('10월 챌린지'), findsOneWidget);
  });

  testWidgets('3개 참가 중이면 이번 달 참가 대신 안내', (tester) async {
    final api = MockChalloryApi();
    api.sessions
      ..removeWhere((s) => s.monthly)
      ..addAll([ChallengeSession.mock, ChallengeSession.mock]);
    await pumpWidgetScreen(tester, const Scaffold(body: ChallengeCards()), overrides: [apiProvider.overrideWithValue(api)]);
    expect(find.text('이번 달 챌린지 참가하기'), findsNothing);
    expect(find.text('동시에 3개까지 참가할 수 있어요'), findsOneWidget);
  });

  testWidgets('앱 안에서 10월 챌린지 카드를 누르면 홈 제목이 바뀐다', (tester) async {
    await pumpApp(tester);
    expect(find.text('10월 챌린지'), findsOneWidget); // 카드 이름만
    await tester.tap(find.text('10월 챌린지'));
    await tester.pumpAndSettle();
    // 앱바 제목 + 카드 이름
    expect(find.text('10월 챌린지'), findsNWidgets(2));
  });

  testWidgets('선택된 카드만 채워진 배경, 나머지는 테두리', (tester) async {
    final api = MockChalloryApi();
    await pumpWidgetScreen(tester, const Scaffold(body: ChallengeCards()), overrides: [apiProvider.overrideWithValue(api)]);
    ChCard cardAt(int i) => tester.widget<ChCard>(find.descendant(of: find.byKey(ValueKey('challenge-card-$i')), matching: find.byType(ChCard)));
    expect(cardAt(0).outline, isFalse); // 가장 최근 참가(목록 첫 카드)가 기본 선택
    expect(cardAt(0).color, isNotNull);
    expect(cardAt(1).outline, isTrue);
    expect(cardAt(1).color, isNull);
    await tester.tap(find.text('10월 챌린지'));
    await tester.pumpAndSettle();
    expect(cardAt(1).outline, isFalse);
    expect(cardAt(1).color, isNotNull);
    expect(cardAt(0).outline, isTrue);
    expect(cardAt(0).color, isNull);
  });

  test('점검 시작 전이면 상태 줄이 비어 있다', () {
    final s = ChallengeSession.mockMonthly; // checkStart 10/1
    expect(ChallengeCards.statusLine(s, DateTime(2026, 9, 30)), '');
    expect(ChallengeCards.statusLine(s, DateTime(2026, 10, 1)), '점검 기간 1/3일');
  });

  testWidgets('초대코드 확인을 두 번 눌러도 조회는 한 번', (tester) async {
    final api = _SlowInviteApi();
    await pumpWidgetScreen(tester, const Scaffold(body: ChallengeCards()), overrides: [apiProvider.overrideWithValue(api)]);
    await tester.tap(find.text('초대코드로 참가'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ZZZZZZ');
    await tester.tap(find.text('확인'));
    await tester.pump();
    await tester.tap(find.text('확인'));
    await tester.pump();
    expect(api.inviteCalls, 1);
    api.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('코드를 다시 확인해 주세요'), findsOneWidget);
  });
}

/// 응답을 직접 풀어 줄 때까지 getInvite 를 붙잡아 둔다
class _SlowInviteApi extends MockChalloryApi {
  final gate = Completer<void>();
  int inviteCalls = 0;
  @override
  Future<InviteSummary?> getInvite(String code) async {
    inviteCalls++;
    await gate.future;
    return null;
  }
}
