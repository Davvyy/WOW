// 아래에서 올라오는 창(전수 점검 #25): 셸의 탭 바·촬영 버튼 위에, 시스템 내비게이션 바(아래 안전 영역)를 피해 뜬다.
import 'package:challory/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 시스템 내비게이션 바 48dp(제스처 바·버튼 바)
const _navBar = 48.0;

Future<void> _pumpWithNavBar(WidgetTester tester) async {
  await pumpApp(tester);
  tester.view.padding = const FakeViewPadding(bottom: _navBar);
  tester.view.viewPadding = const FakeViewPadding(bottom: _navBar);
  await tester.pumpAndSettle();
}

/// [text] 버튼이 탭 바보다 위 층(루트 내비게이터)에 있고, 화면 아래 안전 영역 밖(위)에 있는지
void _expectAboveBars(WidgetTester tester, String text) {
  final btn = find.text(text).last;
  final nav = tester.state<NavigatorState>(find.ancestor(of: btn, matching: find.byType(Navigator)).first);
  expect(nav, same(rootNavigatorKey.currentState), reason: '셸 탭 안이 아니라 루트에 뜬다(탭 바·촬영 버튼이 덮지 않음)');
  final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
  expect(tester.getRect(btn).bottom, lessThanOrEqualTo(screenH - _navBar), reason: '시스템 바에 가리지 않는다');
}

void main() {
  testWidgets('홈 공지 창의 "닫기"', (tester) async {
    await _pumpWithNavBar(tester);
    await tester.tap(find.textContaining('[공지]', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('공지'), findsOneWidget);
    _expectAboveBars(tester, '닫기');
    await tester.tap(find.text('닫기').last);
    await tester.pumpAndSettle();
    expect(find.text('공지'), findsNothing);
  });

  testWidgets('홈 초대코드 창의 "확인"', (tester) async {
    await _pumpWithNavBar(tester);
    await tester.tap(find.text('초대코드로 참가').first);
    await tester.pumpAndSettle();
    _expectAboveBars(tester, '확인');
  });
}
