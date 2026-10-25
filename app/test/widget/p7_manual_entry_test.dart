// P7 '직접 입력' 창(전수 점검 batch C 주의 4): 창이 닫히는 애니메이션이 끝날 때까지 입력 칸이 컨트롤러를 쓴다.
// 컨트롤러를 창이 닫히자마자 dispose 하면 닫히는 동안 다시 그릴 때 'used after being disposed' 단언이 난다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

Future<void> _openManual(WidgetTester tester) async {
  await pumpApp(tester, location: R.meal(MealSlot.lunch, search: true));
  await tester.tap(find.text('직접 입력 (이름·kcal)'));
  await tester.pumpAndSettle();
  expect(find.text('음식 이름'), findsOneWidget);
}

/// 닫히는 애니메이션을 한 프레임씩 흘린다(그 사이 입력 칸이 다시 그려진다)
Future<void> _pumpClosing(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('추가: 닫히는 동안에도 컨트롤러가 살아 있고, 항목이 들어간다', (tester) async {
    await _openManual(tester);
    final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '엄마표 김밥');
    await tester.enterText(fields.at(1), '420');
    await tester.tap(find.text('추가'));
    await _pumpClosing(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('엄마표 김밥'), findsWidgets);
  });

  testWidgets('취소: 닫히는 동안 오류가 없고 항목은 그대로 없다', (tester) async {
    await _openManual(tester);
    final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '떡볶이');
    await tester.tap(find.text('취소'));
    await _pumpClosing(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('떡볶이'), findsNothing);
  });

  testWidgets('바깥을 눌러 닫아도 오류가 없다', (tester) async {
    await _openManual(tester);
    await tester.tapAt(const Offset(8, 8));
    await _pumpClosing(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsNothing);
  });
}
