// P10 산식 카드가 보여 줄 날: 날짜 없이 열면(P11 '오늘 실제값과 비교') 오늘, ?day= 로 열면 그 날.
// 서버 장부는 최신순으로 올 수 있다(PostgREST order 기본 내림차순) — 목록 순서로 '오늘'을 고르지 않는다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 모의 세션: 10.6 시작, 오늘 10.13(D+8)
LedgerRow _row(int d, {bool provisional = false, double s = 20}) {
  final date = DateTime(2026, 10, 5 + d);
  final iso = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  return LedgerRow(
      d: d, date: '${date.month}.${date.day}', steps: 8000, bmr: 1650, a: 300, i: 1500, dd: 450, s: s, f: 1200, floorApplied: false,
      substituted: const [], check: d <= 3, provisional: provisional, note: '', history: '', health: false,
      meals: const [MealInput(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 700)], localDate: iso);
}

class _Remote extends MockChalloryApi {
  _Remote({this.withToday = true, this.ascending = false});
  final bool withToday;

  /// 서버 응답 순서: 기본은 최신순, true 면 날짜 순(첫날 → 오늘)
  final bool ascending;
  @override
  bool get isRemote => true;
  @override
  Future<List<LedgerRow>> fetchLedger() async {
    final rows = [
      // 최신순(서버 응답 그대로)
      if (withToday) _row(8, provisional: true, s: 33.3),
      for (var d = 7; d >= 1; d--) _row(d, s: 10.0 + d),
    ];
    return ascending ? rows.reversed.toList() : rows;
  }
}

Future<ProviderContainer> _pump(WidgetTester tester, String location, _Remote api) async {
  tester.view.physicalSize = const Size(420, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(resetSession);
  final router = buildRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [apiProvider.overrideWithValue(api), authServiceProvider.overrideWithValue(MockAuthService(true))],
    child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
}

void main() {
  testWidgets('P11 "오늘 실제값과 비교": 홈에서 지난날(10.12)을 골라 둬도 오늘(10.13) 계산을 보여 준다', (tester) async {
    final c = await _pump(tester, R.home, _Remote());
    c.read(selectedDayProvider.notifier).set(7);
    await tester.pumpAndSettle();
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push(R.rules);
    await tester.pumpAndSettle();
    final link = find.text('오늘 실제값과 비교');
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.text('점수 장부'), findsOneWidget);
    expect(find.textContaining('10.13 · 잠정'), findsOneWidget);
    expect(find.textContaining('10.6 ·'), findsNothing, reason: '최신순 목록의 마지막 행(첫날)을 오늘로 보지 않는다');
    expect(find.textContaining('33.3점'), findsWidgets);
  });

  testWidgets('P10 날짜 없이: 서버에 오늘 행이 아직 없으면 오늘 잠정 계산(첫날 행이 아님)', (tester) async {
    await _pump(tester, R.ledger, _Remote(withToday: false));
    expect(find.textContaining('오늘 10.13 · 잠정'), findsOneWidget);
    expect(find.textContaining('10.6 ·'), findsNothing);
  });

  testWidgets('P10 ?day=7: 그 날(10.12) 계산', (tester) async {
    await _pump(tester, '${R.ledger}?day=7', _Remote());
    expect(find.textContaining('10.12 · 확정'), findsOneWidget);
    expect(find.textContaining('17.0점'), findsWidgets);
  });

  for (final ascending in [false, true]) {
    testWidgets('P10 일별 표: 최신순(오늘이 맨 위 → 첫날) · 서버 ${ascending ? '날짜 순' : '최신순'} 응답', (tester) async {
      await _pump(tester, R.ledger, _Remote(ascending: ascending));
      const dates = ['10.13', '10.12', '10.11', '10.10', '10.9', '10.8', '10.7', '10.6'];
      final ys = [for (final d in dates) tester.getTopLeft(find.bySemanticsLabel(RegExp('^${RegExp.escape(d)} 점수'))).dy];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i - 1], lessThan(ys[i]), reason: '${dates[i - 1]} 이 ${dates[i]} 보다 위');
      }
      // 오늘 산식 카드는 그대로 오늘
      expect(find.textContaining('10.13 · 잠정'), findsOneWidget);
    });
  }
}
