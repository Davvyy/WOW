// P9 표시: 잠정 행이 있으면 '확정된 점수가 없어요' 빈 화면 대신 한 줄 안내 · '더 보기'는 더 있을 때만 · 잠정 안내 문장
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 점검 기간: 오늘 잠정 행은 나 하나, 확정 누적은 아직 없음, 장부도 비어 있음
class _CheckingApi extends MockChalloryApi {
  @override
  Future<Leaderboard> fetchLeaderboard() async =>
      const Leaderboard(total: 1, today: [LeaderRow(rank: 1, name: '지수', score: 150, me: true, participantId: 'p-1')], cumulative: []);

  @override
  Future<List<LedgerRow>> fetchLedger() async => const [];
}

const _note = '확정 순위는 점검 기간이 끝난 다음 날 09:00부터 보여요';

void main() {
  tearDown(resetSession);

  testWidgets('A8 오늘(잠정) 탭: 내 잠정 행 아래 빈 화면 대신 한 줄 안내, 누적 탭에만 빈 화면', (tester) async {
    await pumpApp(tester, location: R.rank, overrides: [apiProvider.overrideWithValue(_CheckingApi())]);
    expect(find.textContaining('지수(나)'), findsOneWidget);
    expect(find.text('아직 확정된 점수가 없어요'), findsNothing);
    expect(find.text(_note), findsOneWidget);
    expect(find.textContaining('20명씩 더 보기'), findsNothing, reason: '전체 1명 = 보이는 1명');
    expect(find.text('전체 1명'), findsOneWidget);

    await tester.tap(find.text('누적'));
    await tester.pumpAndSettle();
    expect(find.text('아직 확정된 점수가 없어요'), findsOneWidget);
    expect(find.text(_note), findsNothing);
  });

  testWidgets('A8 더 있으면 "20명씩 더 보기"', (tester) async {
    await pumpApp(tester, location: R.rank);
    expect(find.textContaining('20명씩 더 보기'), findsOneWidget, reason: '모의 전체 42명');
  });

  testWidgets('B3 잠정 안내는 한 문장씩', (tester) async {
    await pumpApp(tester, location: R.rank);
    expect(find.text('잠정 순위예요. 매시간 바뀌고 내일 09:00에 확정돼요.'), findsOneWidget);
    expect(find.textContaining('잠정 · 매시간 갱신'), findsNothing);
  });
}
