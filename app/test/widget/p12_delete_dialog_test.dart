// 설정 '계정 삭제' 확인 창: 닫히는 애니메이션이 끝날 때까지 입력 칸이 컨트롤러를 쓴다(직접 입력 창과 같은 문제).
// 취소만 누른다 — 실제 삭제는 하지 않는다.
import 'package:challory/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

void main() {
  testWidgets('계정 삭제 창: "삭제"를 입력하고 취소해도 닫히는 동안 오류가 없다', (tester) async {
    await pumpApp(tester, location: R.settings);
    await tester.scrollUntilVisible(find.text('계정 삭제'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('계정 삭제'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), '삭제');
    await tester.pump();
    await tester.tap(find.text('취소'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsNothing);
  });
}
