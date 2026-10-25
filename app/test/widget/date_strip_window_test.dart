// 모의 장부는 8일치라 지난날은 8일째 안에서 고른다
// 홈 날짜 띠: 7칸 창은 선택한 날을 따라가되 오늘에서 끝난다(31일 챌린지 25일째에 4~10일이 보이던 문제)
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 31일 챌린지의 [dayIndex] 일째가 오늘인 세션
ChallengeSession _onDay(int dayIndex) {
  final base = ChallengeSession.mock;
  final c = base.challenge;
  return ChallengeSession(
    challenge: ChallengeInfo(
      name: c.name, code: c.code, start: c.start, end: c.start.add(const Duration(days: 30)), days: 31,
      capacity: c.capacity, joined: c.joined,
      today: c.start.add(Duration(days: dayIndex - 1)), dayIndex: dayIndex, syncTime: c.syncTime, source: c.source,
      platform: c.platform, noticeTitle: c.noticeTitle, noticeBody: c.noticeBody, noticeDate: c.noticeDate,
      objectionUntil: c.objectionUntil),
    me: base.me,
    rules: base.rules,
    status: base.status,
    challengeId: base.challengeId,
    participantId: base.participantId,
    checkStart: c.start,
  );
}

/// 날짜 띠 칸의 접근성 라벨(예: '10월 25일 일요일 선택됨')
Finder _cell(DateTime d, {bool selected = false}) =>
    find.bySemanticsLabel(RegExp('^${d.month}월 ${d.day}일 .요일${selected ? ' 선택됨' : ''}'));

void main() {
  tearDown(resetSession);

  testWidgets('25일째 오늘: 19~25일째가 보이고 오늘이 선택돼 있다', (tester) async {
    final s = _onDay(25);
    final api = MockChalloryApi()..sessions.replaceRange(0, 1, [s]);
    final container = await pumpApp(tester, location: R.home, overrides: [apiProvider.overrideWithValue(api)]);
    expect(container.read(selectedDayProvider), 25);
    final start = s.challenge.start;
    DateTime dayOf(int n) => DateTime(start.year, start.month, start.day + n - 1);
    expect(_cell(dayOf(25), selected: true), findsOneWidget);
    expect(_cell(dayOf(19)), findsOneWidget);
    expect(_cell(dayOf(18)), findsNothing);
    expect(_cell(dayOf(26)), findsNothing); // 고를 수 없는 미래 칸은 띠에 넣지 않는다
    expect(_cell(dayOf(4)), findsNothing);
  });

  testWidgets('지난날을 고르면 창이 따라간다: 25일째 오늘에 7일째 선택 → 3~9일째', (tester) async {
    final s = _onDay(25);
    final api = MockChalloryApi()..sessions.replaceRange(0, 1, [s]);
    final container = await pumpApp(tester, location: R.home, overrides: [apiProvider.overrideWithValue(api)]);
    container.read(selectedDayProvider.notifier).set(7);
    await tester.pumpAndSettle();
    final start = s.challenge.start;
    DateTime dayOf(int n) => DateTime(start.year, start.month, start.day + n - 1);
    expect(_cell(dayOf(7), selected: true), findsOneWidget);
    expect(_cell(dayOf(3)), findsOneWidget);
    expect(_cell(dayOf(9)), findsOneWidget);
    expect(_cell(dayOf(10)), findsNothing);
  });
}
