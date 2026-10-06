// P9 누적 탭: 아직 순위에 없을 때 상태 카드는 하나(점검 기간 → 순위 대기 → 확정 점수 없음).
// '확정 · M.D 09:00' 칩은 순위 행이 있을 때만, '전체 N명'은 보이는 행이 있을 때만.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/core/format.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

class _Api extends MockChalloryApi {
  _Api(this.cumulative, {DateTime? checkStart}) {
    if (checkStart != null) {
      sessions[0] = ChallengeSession(challenge: mockChallenge, me: mockMe, rules: EngineRules.defaults, status: 'running',
          challengeId: 'mock-challenge', participantId: 'mock-p', checkStart: checkStart);
    }
  }
  final List<LeaderRow> cumulative;

  @override
  Future<Leaderboard> fetchLeaderboard() async => Leaderboard(total: cumulative.length, today: mockLeaderboard.today, cumulative: cumulative);
}

const _stateTitles = ['점검 기간이에요', '순위 대기', '아직 확정된 점수가 없어요'];

Future<void> _openCumulative(WidgetTester tester, MockChalloryApi api) async {
  await pumpApp(tester, location: R.rank, overrides: [apiProvider.overrideWithValue(api)]);
  await tester.tap(find.text('누적'));
  await tester.pumpAndSettle();
}

int _stateCards() => [for (final t in _stateTitles) find.text(t).evaluate().length].fold(0, (a, n) => a + n);

void main() {
  tearDown(resetSession);

  testWidgets('점검 기간: 카드 하나 "점검 기간이에요" · 첫 반영일 · 확정 칩·전체 N명 없음', (tester) async {
    final today = mockChallenge.today;
    await _openCumulative(tester, _Api(const [LeaderRow(rank: 0, name: '지수', pending: true, days: 0, minDays: 1, me: true, participantId: 'p-1')],
        checkStart: today));
    final first = DateTime(today.year, today.month, today.day + EngineRules.defaults.checkDays);
    expect(find.text('점검 기간이에요'), findsOneWidget);
    expect(find.text('${fmtMd(first)}부터 누적 순위에 들어가요.'), findsOneWidget);
    expect(_stateCards(), 1);
    expect(find.textContaining('확정 · '), findsNothing);
    expect(find.textContaining('전체 '), findsNothing);
  });

  testWidgets('점검 기간이 끝나고 참여일이 모자라면 "순위 대기" · 참여 n/m일', (tester) async {
    await _openCumulative(tester, _Api(const [LeaderRow(rank: 0, name: '지수', pending: true, days: 3, minDays: 7, me: true, participantId: 'p-1')]));
    expect(find.text('순위 대기'), findsOneWidget);
    expect(find.text('참여 3/7일 · 7일 채우면 순위에 들어가요.'), findsOneWidget);
    expect(_stateCards(), 1);
    expect(find.textContaining('확정 · '), findsNothing, reason: '순위 행이 없다');
  });

  testWidgets('순위 행이 있으면 확정 칩, 상태 카드 없음', (tester) async {
    await _openCumulative(tester, MockChalloryApi());
    expect(find.textContaining('확정 · ${fmtMd(mockChallenge.today)} 09:00'), findsOneWidget);
    expect(_stateCards(), 0);
    expect(find.textContaining('전체 '), findsOneWidget);
  });

  testWidgets('아무도 누적 행이 없고 점검 기간도 아니면 "아직 확정된 점수가 없어요" 하나만', (tester) async {
    await _openCumulative(tester, _Api(const []));
    expect(find.text('아직 확정된 점수가 없어요'), findsOneWidget);
    expect(_stateCards(), 1);
    expect(find.textContaining('확정 · '), findsNothing);
    expect(find.textContaining('전체 '), findsNothing);
  });
}
