// 활동 탭 '최근 7일 활동 kcal' 읽기 라벨(전수 점검 #27): 월은 그 날짜의 실제 월(10월 고정 아님).
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/state/app_state.dart';
import 'package:flutter/widgets.dart' show Semantics;
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

void main() {
  testWidgets('10.31 · 11.1 · 11.2 장부 → "10월 31일 … 11월 1일 … 11월 2일"', (tester) async {
    final rows = [
      for (final d in ['2026-10-31', '2026-11-01', '2026-11-02'])
        ledgerRowFromServer({'local_date': d, 'bmr': 1650, 'a_d': 200, 'i_d': 1500, 'f_p': 1200, 'd_d': 300, 's_d': 60, 'is_counted': true,
          'is_final': true, 'breakdown': const <String, dynamic>{}}, mockChallenge.start),
    ];
    await pumpApp(tester, location: R.activity, overrides: [ledgerProvider.overrideWith((ref) async => rows)]);
    final label = tester
        .widget<Semantics>(find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith('최근 7일 활동 칼로리')))
        .properties
        .label!;
    expect(label, contains('10월 31일 200'));
    expect(label, contains('11월 1일 200'));
    expect(label, contains('11월 2일 200'));
    expect(label, isNot(contains('10월 1일')));
  });
}
