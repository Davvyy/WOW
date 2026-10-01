// 서버 모드(isRemote) 화면: 리더보드·장부를 서버 응답(픽스처)으로 그리고, 신고는 스냅샷의 participant_id 로 보낸다.
import 'dart:convert';
import 'dart:io';

import 'package:challory/data/mock/mock_data.dart' show Leaderboard;
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _f = jsonDecode(File('test/fixtures/server_ledger.json').readAsStringSync()) as Map<String, dynamic>;

class _RemoteFake extends MockChalloryApi {
  final reported = <String?>[];
  @override
  bool get isRemote => true;
  @override
  Future<Leaderboard> fetchLeaderboard() async => leaderboardFromServer(
        todayRows: _f['snapshot_today'] as List,
        cumulativeRows: _f['snapshot_cumulative'] as List,
        myParticipantId: _f['participant_id'] as String,
        myNickname: '지수',
        myToday: 28.8,
        myCumulative: 312.6,
      );
  @override
  Future<List<LedgerRow>> fetchLedger() async {
    final start = DateTime.parse(_f['start_date'] as String);
    final revs = (_f['revisions'] as List).cast<Map<String, dynamic>>();
    final types = {for (final r in (_f['reviews'] as List)) (r as Map)['id'] as String: r['type'] as String};
    return [
      for (final r in (_f['daily_scores'] as List).cast<Map<String, dynamic>>())
        ledgerRowFromServer(r, start, revisions: [for (final v in revs) if (v['daily_score_id'] == r['id']) v], reviewTypes: types),
    ];
  }

  @override
  Future<void> report({String? participantId, String? mealId, required String reason, required String idempotencyKey}) async =>
      reported.add(participantId);
}

Future<void> _pump(WidgetTester tester, String location, _RemoteFake api) async {
  tester.view.physicalSize = const Size(420, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [apiProvider.overrideWithValue(api)],
    child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('P9 누적: 서버 스냅샷 · 내 행 312.6 · 집계 중 행', (tester) async {
    final api = _RemoteFake();
    await _pump(tester, R.rank, api);
    await tester.tap(find.text('누적'));
    await tester.pumpAndSettle();
    expect(find.text('312.6'), findsWidgets);
    expect(find.textContaining('집계 중'), findsWidgets);
  });

  testWidgets('P9 신고: 스냅샷 participant_id 로 서버에 보냄', (tester) async {
    final api = _RemoteFake();
    await _pump(tester, R.rank, api);
    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('익명으로 신고'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('신고하기'));
    await tester.pumpAndSettle();
    expect(api.reported, hasLength(1));
    final ids = [for (final r in (_f['snapshot_today'] as List)) (r as Map)['participant_id']];
    expect(ids, contains(api.reported.single));
  });

  testWidgets('P10 장부: 서버 값 · 누적 312.6 · 정정 이력', (tester) async {
    await _pump(tester, R.ledger, _RemoteFake());
    expect(find.textContaining('누적 312.6점'), findsOneWidget);
    expect(find.textContaining('판정 41.2→12.7점'), findsOneWidget);
    expect(find.textContaining('같은 사진이 두 번 이상 사용됐어요'), findsOneWidget);
  });
}
