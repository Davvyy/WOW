// P9 익명 신고(전수 점검 #10): 대상 칸은 실제 닉네임만(신고는 참가자 단위라 날짜·끼니가 없다).
// 신고할 다른 참가자가 없으면 '익명으로 신고' 메뉴를 보이지 않는다.
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 오늘 순위에 나 혼자
class _SoloApi extends MockChalloryApi {
  @override
  Future<Leaderboard> fetchLeaderboard() async =>
      const Leaderboard(total: 1, today: [LeaderRow(rank: 1, name: '지수', score: 150, me: true, participantId: 'p-1')], cumulative: []);
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('더보기'));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(resetSession);

  testWidgets('신고 창 대상 칸: 닉네임만, 시안 날짜(10.12 저녁) 없음', (tester) async {
    await pumpApp(tester, location: R.rank);
    await tester.longPress(find.textContaining('오이냉국'));
    await tester.pumpAndSettle();
    expect(find.text('익명으로 신고'), findsOneWidget);
    expect(find.text('오이냉국'), findsWidgets);
    expect(find.textContaining('10.12'), findsNothing);
    expect(find.textContaining('오이냉국 · '), findsNothing);
  });

  testWidgets('메뉴의 익명으로 신고: 첫 다른 참가자의 실제 닉네임', (tester) async {
    await pumpApp(tester, location: R.rank);
    await _openMenu(tester);
    await tester.tap(find.text('익명으로 신고'));
    await tester.pumpAndSettle();
    final target = mockLeaderboard.today.firstWhere((r) => !r.me && !r.aggregating).name;
    expect(find.text('신고하기'), findsOneWidget);
    expect(find.text(target), findsWidgets);
    expect(find.textContaining(' · 10.12'), findsNothing);
  });

  testWidgets('참가자가 나 혼자면 메뉴에 신고가 없고 나가기만 있다', (tester) async {
    await pumpApp(tester, location: R.rank, overrides: [apiProvider.overrideWithValue(_SoloApi())]);
    await _openMenu(tester);
    expect(find.text('익명으로 신고'), findsNothing);
    expect(find.text('챌린지 나가기'), findsOneWidget);
    expect(find.byType(PopupMenuItem<String>), findsOneWidget);
  });
}
