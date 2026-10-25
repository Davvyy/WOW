// 홈 순위 줄: 순위 점수(일평균 × (1 + 참여율), D49)가 누적 합계와 다르면 함께 보인다 ·
// P9 누적 탭의 내 줄 반영률도 오늘 탭·홈과 같은 실시간 값(D69)
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 누적 순위표에 나 혼자, 순위 점수 1.4(누적 합계와 다른 척도) · 오늘 행은 반영 0칸
class _SoloApi extends MockChalloryApi {
  @override
  Future<Leaderboard> fetchLeaderboard() async => Leaderboard(
        total: 1,
        today: const [LeaderRow(rank: 1, name: '지수', score: 0, fill: 0, me: true, participantId: 'p-1')],
        cumulative: const [LeaderRow(rank: 1, name: '지수', score: 1.4, fill: 0, me: true, participantId: 'p-1', avg: 0.8, rate: 0.86)],
      );
}

String? _myRowLabel(WidgetTester tester) => tester
    .widgetList<Semantics>(find.byType(Semantics))
    .map((s) => s.properties.label)
    .firstWhere((l) => l != null && l.contains('지수(나)') && l.contains('반영률'), orElse: () => null);

void main() {
  tearDown(resetSession);

  testWidgets('홈: 순위 점수가 누적 합계와 다르면 "순위 점수 1.4 · 잠정 1위"', (tester) async {
    await pumpApp(tester, overrides: [apiProvider.overrideWithValue(_SoloApi())]);
    expect(find.text('순위 점수 1.4 · 잠정 1위'), findsOneWidget);
  });

  testWidgets('홈: 순위 점수가 누적 합계와 같으면 순위만(모의 312.6)', (tester) async {
    await pumpApp(tester);
    expect(find.text('누적 $mockCumulative점'), findsOneWidget);
    expect(find.text('잠정 4위'), findsOneWidget);
    expect(find.textContaining('· 잠정 4위'), findsNothing);
  });

  testWidgets('P9 누적 탭 내 줄 반영률 = 오늘 탭 내 줄 반영률(실시간)', (tester) async {
    await pumpApp(tester, location: R.rank, overrides: [apiProvider.overrideWithValue(_SoloApi())]);
    final todayLabel = _myRowLabel(tester);
    expect(todayLabel, isNotNull);
    final todayPct = RegExp(r'반영률 (\d+)%').firstMatch(todayLabel!)!.group(1);
    expect(todayPct, isNot('0'), reason: '모의 오늘 끼니가 있어 실시간 반영률은 0이 아니다');
    await tester.tap(find.text('누적'));
    await tester.pumpAndSettle();
    final cumLabel = _myRowLabel(tester);
    expect(cumLabel, contains('반영률 $todayPct%'));
  });
}
