// 챌린지를 바꾸면 날짜 선택·규칙 탭·오늘 응원이 새 챌린지를 따른다
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/day_timeline.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

void main() {
  tearDown(resetSession);

  testWidgets('홈에서 10월 챌린지로 바꾸면 날짜가 그 챌린지의 오늘로', (tester) async {
    await pumpApp(tester);
    expect(find.text('D+8/28'), findsOneWidget);
    await tester.tap(find.text('10월 챌린지'));
    await tester.pumpAndSettle();
    final today = ChallengeSession.mockMonthly.challenge.dayIndex;
    expect(today, isNot(8));
    expect(find.text('D+$today/31'), findsOneWidget);
    expect(find.text('D+8/31'), findsNothing);
    expect(tester.widget<DayTimelineRow>(find.byType(DayTimelineRow).first).onTap, isNotNull, reason: '오늘이라 끼니를 누를 수 있다');
  });

  testWidgets('규칙 탭은 선택한 챌린지를 따른다', (tester) async {
    final c = await pumpApp(tester, location: R.rules);
    expect(find.text('가을 걷기 챌린지'), findsOneWidget);
    expect(find.text('매달 1일에 새 챌린지가 열려요'), findsNothing);
    c.read(selectedChallengeProvider.notifier).select('mock-monthly');
    await tester.pumpAndSettle();
    expect(find.text('10월 챌린지'), findsOneWidget);
    expect(find.text('매달 1일에 새 챌린지가 열려요'), findsOneWidget);
  });

  testWidgets('짧은 챌린지도 순위 진입 최소 참여일은 1일 이상', (tester) async {
    final m = mockChallenge;
    final short = ChallengeSession(
      challenge: ChallengeInfo(name: '짧은 챌린지', code: '', start: m.start, end: m.start.add(const Duration(days: 3)), days: 4, capacity: 0,
          joined: 3, today: m.start, dayIndex: 1, syncTime: m.syncTime, source: m.source, platform: m.platform, noticeTitle: '',
          noticeBody: '', noticeDate: '', objectionUntil: ''),
      me: mockMe,
      rules: EngineRules.defaults,
      status: 'running',
      challengeId: 'short',
      participantId: 'p-short',
    );
    final api = MockChalloryApi()
      ..sessions.clear()
      ..sessions.add(short);
    await pumpApp(tester, location: R.rules, overrides: [apiProvider.overrideWithValue(api)]);
    expect(find.text('참여일을 1일 채우면 순위에 들어가요(그 전에는 순위 대기)'), findsOneWidget);
  });

  test('응원은 챌린지마다: A에서 보낸 뒤 B로 바꾸면 다시 보낼 수 있다', () async {
    final api = _RemoteMock();
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api), authServiceProvider.overrideWithValue(MockAuthService(true))]);
    addTearDown(c.dispose);
    c.listen(heartedTodayProvider, (_, _) {});
    await c.read(sessionProvider.future);
    expect(await c.read(heartedTodayProvider.notifier).send(const LeaderRow(rank: 2, name: '강남콩', participantId: 'p-a')), isNull);
    expect(c.read(heartedTodayProvider), 'p-a');

    c.read(selectedChallengeProvider.notifier).select('mock-monthly');
    await c.read(sessionProvider.future);
    await pumpEventQueue();
    expect(c.read(heartedTodayProvider), isNull);

    // 돌아가면 그 챌린지에서 보낸 응원을 서버에서 다시 읽는다
    c.read(selectedChallengeProvider.notifier).select('mock-challenge');
    await c.read(sessionProvider.future);
    await pumpEventQueue();
    expect(c.read(heartedTodayProvider), 'p-a');
  });
}

class _RemoteMock extends MockChalloryApi {
  @override
  bool get isRemote => true;
}
