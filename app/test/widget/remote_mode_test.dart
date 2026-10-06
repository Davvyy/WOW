// 서버 모드(isRemote) 화면: 리더보드·장부를 서버 응답(픽스처)으로 그리고, 신고는 스냅샷의 participant_id 로 보낸다.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:challory/data/mock/mock_data.dart' show Leaderboard;
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _f = jsonDecode(File('test/fixtures/server_ledger.json').readAsStringSync()) as Map<String, dynamic>;

class _RemoteFake extends MockChalloryApi {
  _RemoteFake({this.noSession = false, this.status, this.underReview = false});
  final bool noSession;
  final String? status;
  final bool underReview;
  final reported = <String?>[];

  /// 채워 두면 다음 세션 목록 응답을 붙잡아 둔다(다시 읽는 중 화면 확인용)
  Completer<void>? hold;
  @override
  bool get isRemote => true;
  @override
  Future<List<ChallengeSession>> fetchSessions() async {
    if (hold != null) await hold!.future;
    final s = await fetchSession();
    return s == null ? const [] : [s];
  }
  @override
  Future<ChallengeSession?> fetchSession() async => noSession
      ? null
      : sessionFromSummary(
          Map<String, dynamic>.from(_f['summary'] as Map)
            ..['challenge'] = {...(_f['summary'] as Map)['challenge'] as Map, if (status != null) 'status': status},
          today: DateTime(2026, 10, 13));

  @override
  Future<Leaderboard> fetchLeaderboard() async => leaderboardFromServer(
        // 검토 중이면 서버 스냅샷에서 내 행이 '집계 중'으로 가려진다
        todayRows: [
          for (final r in _f['snapshot_today'] as List)
            if (!(underReview && (r as Map)['participant_id'] == _f['participant_id'])) r,
        ],
        cumulativeRows: _f['snapshot_cumulative'] as List,
        myParticipantId: _f['participant_id'] as String,
        myNickname: '지수',
        myToday: 28.8,
        myCumulative: 312.6,
        myUnderReview: underReview,
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
  addTearDown(resetSession);
  await tester.pumpWidget(ProviderScope(
    overrides: [apiProvider.overrideWithValue(api), authServiceProvider.overrideWithValue(MockAuthService(true))],
    child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('P9 누적: 서버 스냅샷 · 내 행 순위 점수 156.3 · 집계 중 행', (tester) async {
    final api = _RemoteFake();
    await _pump(tester, R.rank, api);
    await tester.tap(find.text('누적'));
    await tester.pumpAndSettle();
    expect(find.text('156.3'), findsWidgets);
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

  testWidgets('P11 규칙: 서버 시간 규칙·끼니 경계·운영자 추가 규칙', (tester) async {
    await _pump(tester, R.rules, _RemoteFake());
    expect(find.text('D+1 09:00 확정'), findsOneWidget);
    expect(find.text('아침 04:00~10:30 · 점심 ~15:00 · 저녁 ~22:00 · 그 외 간식'), findsOneWidget);
    expect(find.text('운영자 추가 규칙'), findsOneWidget);
    expect(find.textContaining('상위 3명'), findsOneWidget);
  });

  testWidgets('P5 머리글: 서버 챌린지 이름·D+n', (tester) async {
    await _pump(tester, R.home, _RemoteFake());
    expect(find.text('가을 걷기 챌린지'), findsWidgets);
    expect(find.textContaining('D+8/28'), findsWidgets);
  });

  testWidgets('P5 검토 배너: source_unknown 이면 그 사유를 보여주고 걸음 급증 문구는 쓰지 않는다', (tester) async {
    final api = _RemoteFake(underReview: true)
      ..reviews.add(MyReview(id: 'rv3', type: 'source_unknown', status: 'open', localDate: DateTime(2026, 10, 13)));
    await _pump(tester, R.home, api);
    // 한 줄은 짧게, 사유 문장 전체는 읽기 이름에
    expect(find.text('운동 기록을 확인 중이에요'), findsOneWidget);
    expect(find.bySemanticsLabel('확인되지 않은 출처의 운동 기록이 있었어요. 72시간 안에 설명을 남길 수 있어요.'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('평소의 2.5배')), findsNothing);
  });

  testWidgets('P5 검토 안내: 다른 사유는 그 사유 문장을 한 줄로', (tester) async {
    final api = _RemoteFake(underReview: true)
      ..reviews.add(MyReview(id: 'rv5', type: 'dup_photo', status: 'open', localDate: DateTime(2026, 10, 13)));
    await _pump(tester, R.home, api);
    expect(find.text('같은 사진이 두 번 이상 사용됐어요'), findsOneWidget);
    expect(find.text('운동 기록을 확인 중이에요'), findsNothing);
  });

  testWidgets('P5 검토 배너: steps_spike 이면 걸음 급증 문구', (tester) async {
    final api = _RemoteFake(underReview: true)
      ..reviews.add(MyReview(id: 'rv4', type: 'steps_spike', status: 'open', localDate: DateTime(2026, 10, 13)));
    await _pump(tester, R.home, api);
    expect(find.text('운동 기록을 확인 중이에요'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('평소의 2.5배를 넘어 검토 중이에요')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('확인되지 않은 출처')), findsNothing);
  });

  testWidgets('P5 검토 배너: 검토 목록이 비어 있으면 일반 문구', (tester) async {
    await _pump(tester, R.home, _RemoteFake(underReview: true));
    expect(find.text('기록을 확인하고 있어요'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('평소의 2.5배')), findsNothing);
  });

  testWidgets('세션 목록을 다시 읽는 동안 홈을 로딩 화면으로 바꾸지 않는다', (tester) async {
    final api = _RemoteFake();
    await _pump(tester, R.home, api);
    expect(find.text('가을 걷기 챌린지'), findsWidgets);
    final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    api.hold = Completer<void>();
    c.invalidate(sessionsProvider); // 참가·나가기·판정 푸시·온보딩 뒤와 같음
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(c.read(sessionProvider).isLoading, isTrue, reason: '다시 읽는 중');
    expect(find.text('챌린지를 불러오고 있어요'), findsNothing);
    expect(find.text('가을 걷기 챌린지'), findsWidgets);
    api.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.text('가을 걷기 챌린지'), findsWidgets);
  });

  testWidgets('참가 중인 챌린지가 없으면 이번 달 챌린지·초대코드 안내 → P1', (tester) async {
    await _pump(tester, R.home, _RemoteFake(noSession: true));
    expect(find.text('참가 중인 챌린지가 없어요'), findsOneWidget);
    expect(find.text('이번 달 챌린지에 참가하거나 초대코드로 참가할 수 있어요'), findsOneWidget);
    await tester.tap(find.text('참가하러 가기'));
    await tester.pumpAndSettle();
    expect(find.text('이번 달 챌린지 참가하기'), findsOneWidget, reason: 'P1');
  });

  testWidgets('P9 응원: 서버 participant_id 로 보내고 하루 1회', (tester) async {
    final api = _RemoteFake();
    await _pump(tester, R.rank, api);
    final hearts = find.byIcon(Icons.favorite_border_rounded);
    expect(hearts, findsWidgets);
    await tester.tap(hearts.first);
    await tester.pump();
    final ids = [for (final r in (_f['snapshot_today'] as List)) (r as Map)['participant_id']];
    expect(ids, contains(api.cheeredTo));
    await tester.pumpAndSettle(const Duration(seconds: 3));
    await tester.tap(find.byIcon(Icons.favorite_border_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('내일 다시 응원할 수 있어요'), findsOneWidget);
    expect(api.cheeredTo, isNotNull, reason: '두 번째 응원은 서버로 보내지 않음');
  });

  testWidgets('P10 검토 카드: 서버 사유·기한 → 소명 보내기', (tester) async {
    final api = _RemoteFake()
      ..reviews.add(MyReview(id: 'rv1', type: 'dup_photo', status: 'open', reasonTemplate: 'dup_photo', localDate: DateTime(2026, 10, 12),
          slaDueAt: DateTime.utc(2026, 10, 16, 0)));
    await _pump(tester, R.ledger, api);
    expect(find.textContaining('같은 사진이 두 번 이상 사용됐어요 · 검토 중'), findsOneWidget);
    expect(find.textContaining('10.16 09:00까지'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '10.10 저녁과 같은 접시를 다시 찍었어요.');
    await tester.pump();
    await tester.tap(find.text('설명 보내기'));
    await tester.pumpAndSettle();
    expect(api.appeals['rv1'], '10.10 저녁과 같은 접시를 다시 찍었어요.');
    expect(find.textContaining('설명을 보냈어요.'), findsOneWidget);
  });

  testWidgets('P10 미확인 출처 검토: 출처 이름 · 시각 범위 · 걸음', (tester) async {
    final api = _RemoteFake()
      ..reviews.add(MyReview(id: 'rv6', type: 'source_unknown', status: 'open', localDate: DateTime(2026, 10, 12),
          origin: 'com.android.healthconnect.phone.a1', sourceSteps: 3200,
          firstAt: DateTime.utc(2026, 10, 12, 0, 12), lastAt: DateTime.utc(2026, 10, 12, 12, 40)));
    await _pump(tester, R.ledger, api);
    expect(find.textContaining('확인되지 않은 출처의 운동 기록이 있었어요 · 검토 중'), findsOneWidget);
    expect(find.text('휴대폰 센서 · 09:12–21:40 · 3,200보'), findsOneWidget);
  });

  testWidgets('P10 미확인 출처 검토: 상세가 없으면 출처 이름만', (tester) async {
    final api = _RemoteFake()
      ..reviews.add(MyReview(id: 'rv7', type: 'source_unknown', status: 'open', localDate: DateTime(2026, 10, 12), origin: 'com.example.stepper'));
    await _pump(tester, R.ledger, api);
    expect(find.text('com.example.stepper'), findsOneWidget);
    expect(find.textContaining('com.example.stepper ·'), findsNothing);
  });

  testWidgets('P10 판정 통지: 서버 문장(사유+판정+점수 영향) 그대로', (tester) async {
    final api = _RemoteFake()
      ..reviews.add(const MyReview(id: 'rv2', type: 'dup_photo', status: 'decided', verdict: 'void',
          message: '같은 사진이 두 번 이상 사용됐어요. 대체값 743으로 다시 계산했어요. 10.12 41.2→12.7점 · 누적 −28.5'));
    await _pump(tester, R.ledger, api);
    expect(find.text('같은 사진이 두 번 이상 사용됐어요. 대체값 743으로 다시 계산했어요. 10.12 41.2→12.7점 · 누적 −28.5'), findsOneWidget);
  });

  testWidgets('P10 결과 이의: 발표 후 1회', (tester) async {
    final api = _RemoteFake(status: 'published');
    await _pump(tester, R.ledger, api);
    expect(find.text('최종 결과에 이의 남기기'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '10.12 저녁은 다른 날 사진이에요.');
    await tester.pump();
    await tester.tap(find.text('이의 보내기'));
    await tester.pumpAndSettle();
    expect(api.objection, '10.12 저녁은 다른 날 사진이에요.');
    expect(find.textContaining('이의를 남겼어요'), findsWidgets);
    expect(find.text('이의 보내기'), findsNothing, reason: '1회만 — 입력 카드가 사라짐');
  });
}
