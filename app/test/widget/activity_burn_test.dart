// 홈과 활동 탭의 소비·활동 kcal 은 같은 계산·같은 반올림(정수)이고, 활동 탭에는 워치 예시 보기가 없다.
import 'package:challory/core/burn.dart';
import 'package:challory/core/format.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/state/session.dart';
import 'package:flutter/widgets.dart' show Semantics;
import 'package:challory/router.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 걸음 11,959 → 소수 활동 kcal(정수로 보여야 한다)
class _Steps extends ActivityNotifier {
  @override
  TodayActivity build() => const TodayActivity(stepsTotal: 11959, stepsRecorded: 11959);
}

void main() {
  _weekBars();
  testWidgets('A6 홈 소비·활동 = 활동 탭 소비·활동(정수)', (tester) async {
    final c = await pumpApp(tester, overrides: [activityProvider.overrideWith(_Steps.new)]);
    final sim = c.read(todayResultProvider);
    expect(sim.activity.aD % 1, isNot(0), reason: '소수 활동 kcal 로 확인');
    final b = BurnFigures.of(sim);
    final total = fmtInt(b.total), act = fmtInt(b.activity);
    expect(find.textContaining('약 $total'), findsOneWidget, reason: '홈 숫자 셋 소비');
    expect(find.textContaining('활동 약 $act kcal'), findsOneWidget, reason: '홈 활동 카드');

    await tester.tap(find.text('활동').last);
    await tester.pumpAndSettle();
    expect(find.text('소비 분해'), findsOneWidget);
    expect(find.text(total), findsOneWidget, reason: '= 소비 (추정)');
    expect(find.text('활동 $act'), findsOneWidget);
    expect(find.text(fmtInt(b.steps)), findsWidgets, reason: '+ 걸음 · 7일 막대의 오늘');
    expect(find.text(fmtK1(sim.activity.aD)), findsNothing, reason: '소수 1자리 kcal 은 보이지 않는다');
  });

  testWidgets('A9 활동 탭: 워치 예시 보기와 보기 전환이 없다', (tester) async {
    await pumpApp(tester, location: R.activity);
    expect(find.text('소비 분해'), findsOneWidget);
    expect(find.textContaining('워치 예시'), findsNothing);
    expect(find.textContaining('밤산책'), findsNothing);
    expect(find.byType(ChSeg<bool>), findsNothing);
  });
}

LedgerRow _row(LedgerRow base, {required double a, required bool provisional}) => LedgerRow(
      d: base.d, date: base.date, steps: base.steps, bmr: base.bmr, a: a, i: base.i, dd: base.dd, s: base.s, f: base.f,
      floorApplied: base.floorApplied, substituted: base.substituted, check: base.check, provisional: provisional,
      note: base.note, history: base.history, health: base.health, meals: base.meals);

void _weekBars() {
  testWidgets('최근 7일 막대: 확정 전 지난 날은 그날 값, 오늘만 현재 계산값', (tester) async {
    final today = curChallenge.dayIndex;
    final rows = [for (final r in mockLedger.where((r) => r.d <= today)) r];
    final last3 = rows.sublist(rows.length - 3);
    final ledger = [
      ...rows.sublist(0, rows.length - 3),
      _row(last3[0], a: 7.9, provisional: true),
      _row(last3[1], a: 0, provisional: true),
      _row(last3[2], a: 0, provisional: true), // 오늘: 현재 계산값으로 바뀌어야 한다
    ];
    final c = await pumpApp(tester, location: R.activity, overrides: [
      activityProvider.overrideWith(_Steps.new),
      ledgerProvider.overrideWith((ref) async => ledger),
    ]);
    final todayA = c.read(todayResultProvider).activity.aD;
    final bars = tester.widget<Semantics>(find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith('최근 7일 활동 칼로리')));
    final label = bars.properties.label!;
    expect(label, contains('${last3[0].date.split('.').last}일 8'), reason: '7.9 → 8');
    expect(label, contains('${last3[1].date.split('.').last}일 0'));
    expect(label, contains('${last3[2].date.split('.').last}일 ${fmtInt(todayA)}'), reason: '오늘은 현재 계산값');
  });
}
