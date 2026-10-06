// P9: 챌린지 전환 · 일평균·참여율 · 순위 대기 · 챌린지 나가기
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

class _Api extends MockChalloryApi {
  @override
  Future<Leaderboard> fetchLeaderboard() async {
    calls.add('leaderboard');
    return Leaderboard(total: 3, today: mockLeaderboard.today, cumulative: const [
      LeaderRow(rank: 1, name: '하니', score: 90, avg: 60, rate: 0.5, days: 14, minDays: 7, participantId: 'p-2'),
      LeaderRow(rank: 2, name: '지수', score: 80, avg: 40, rate: 1.0, days: 28, minDays: 7, me: true, participantId: 'p-1'),
      LeaderRow(rank: 0, name: '늦은참가', pending: true, days: 3, minDays: 7, participantId: 'p-3'),
    ]);
  }
}

class _PendingMeApi extends MockChalloryApi {
  @override
  Future<Leaderboard> fetchLeaderboard() async {
    calls.add('leaderboard');
    return Leaderboard(total: 3, today: mockLeaderboard.today, cumulative: const [
      LeaderRow(rank: 1, name: '하니', score: 90, avg: 60, rate: 0.5, days: 14, minDays: 7, participantId: 'p-2'),
      LeaderRow(rank: 0, name: '지수', pending: true, days: 3, minDays: 7, me: true, participantId: 'p-1'),
      LeaderRow(rank: 0, name: '늦은참가', pending: true, days: 2, minDays: 7, participantId: 'p-3'),
    ]);
  }
}

void main() {
  tearDown(resetSession);

  testWidgets('누적: 일평균·참여율, 순위 대기 묶음, 챌린지 전환 칩', (tester) async {
    await pumpApp(tester, location: R.rank, overrides: [apiProvider.overrideWithValue(_Api())]);
    await tester.tap(find.text('누적'));
    await tester.pumpAndSettle();
    expect(find.text('일평균 60.0점 · 참여율 50%'), findsOneWidget);
    expect(find.text('순위 대기'), findsOneWidget);
    expect(find.textContaining('늦은참가 · 참여 3/7일'), findsOneWidget);
    expect(find.text('10월 챌린지'), findsWidgets);
    expect(find.text('가을 걷기 챌린지'), findsWidgets);
  });

  testWidgets('챌린지 나가기: 확인 문구 → 나가면 목록에서 빠짐', (tester) async {
    final api = _Api();
    await pumpApp(tester, location: R.rank, overrides: [apiProvider.overrideWithValue(api)]);
    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('챌린지 나가기'));
    await tester.pumpAndSettle();
    expect(find.text('순위에서 빠지고 기록은 보관돼요 · 이 챌린지에는 다시 참가할 수 없어요'), findsOneWidget);
    await tester.tap(find.text('나가기').last); // 대화상자의 '나가기' 버튼(메뉴의 '챌린지 나가기'는 닫혀 있음)
    await tester.pumpAndSettle();
    expect(api.sessions.length, 1);
    expect(find.text('챌린지에서 나갔어요'), findsOneWidget);
  });

  testWidgets('순위 비공개 + 누적: 일평균 줄이 있어도 내 행 고정 영역이 넘치지 않음', (tester) async {
    final container = await pumpApp(tester, location: R.rank, overrides: [apiProvider.overrideWithValue(_Api())]);
    container.read(rankVisibleProvider.notifier).set(false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('누적'));
    await tester.pumpAndSettle();
    expect(find.text('일평균 40.0점 · 참여율 100%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('내가 순위 대기면 카드만 보이고 목록에는 다시 나오지 않음', (tester) async {
    await pumpApp(tester, location: R.rank, overrides: [apiProvider.overrideWithValue(_PendingMeApi())]);
    await tester.tap(find.text('누적'));
    await tester.pumpAndSettle();
    // 누적 탭 상태 카드 하나(제목 '순위 대기' + 참여 n/m일) · 다른 대기 참가자 묶음 제목도 '순위 대기'
    expect(find.text('참여 3/7일 · 7일 채우면 순위에 들어가요.'), findsOneWidget);
    expect(find.text('순위 대기'), findsNWidgets(2));
    expect(find.text('아직 확정된 점수가 없어요'), findsNothing);
    expect(find.textContaining('지수 · 참여'), findsNothing);
    expect(find.textContaining('늦은참가 · 참여 2/7일'), findsOneWidget);
  });
}
