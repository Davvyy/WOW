// 아래 탭: 홈·순위·촬영·활동·규칙 이름이 한 줄(같은 높이)에 놓인다.
import 'package:challory/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

void main() {
  for (final width in [360.0, 420.0]) {
    testWidgets('A10 ${width.toInt()}dp: 다섯 탭 이름의 위·아래 위치가 1px 안에서 같다', (tester) async {
      await pumpApp(tester);
      tester.view.physicalSize = Size(width, 2600);
      await tester.pumpAndSettle();
      final bar = find.descendant(of: find.byType(AppShell), matching: find.byKey(const ValueKey('tab-bar')));
      expect(bar, findsOneWidget);
      final rects = {for (final l in ['홈', '순위', '촬영', '활동', '규칙']) l: tester.getRect(find.descendant(of: bar, matching: find.text(l)))};
      final ref = rects['홈']!;
      for (final e in rects.entries) {
        expect((e.value.top - ref.top).abs(), lessThanOrEqualTo(1), reason: '${e.key} top ${e.value.top} vs 홈 ${ref.top}');
        expect((e.value.bottom - ref.bottom).abs(), lessThanOrEqualTo(1), reason: '${e.key} bottom ${e.value.bottom} vs 홈 ${ref.bottom}');
      }
      // 탭은 48dp 이상
      for (final l in ['홈', '순위', '활동', '규칙']) {
        expect(tester.getSize(find.ancestor(of: find.descendant(of: bar, matching: find.text(l)), matching: find.byType(InkWell)).first).height, greaterThanOrEqualTo(48));
      }
    });
  }
}
