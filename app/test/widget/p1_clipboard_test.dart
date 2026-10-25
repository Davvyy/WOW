// P1 초대코드 붙여넣기(전수 점검 #11): 실제 클립보드에 6자리 초대코드가 있을 때만 배너를 보인다.
// 시안 코드(K7Q2MD)를 "복사한 코드"로 보이지 않는다.
import 'package:challory/router.dart';
import 'package:challory/ui/screens/p1_start.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 클립보드 내용을 정해 둔다(null 이면 비어 있음)
void _clipboard(WidgetTester tester, String? text) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') return text == null ? null : {'text': text};
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

Future<void> _openCode(WidgetTester tester) async {
  await pumpApp(tester, location: R.p1);
  await tester.tap(find.text('초대코드가 있어요'));
  await tester.pumpAndSettle();
}

void main() {
  group('inviteCodeIn', () {
    test('6자리 영문·숫자만 있으면 대문자로', () {
      expect(inviteCodeIn('ab12cd'), 'AB12CD');
      expect(inviteCodeIn('  H3XK9P \n'), 'H3XK9P');
    });
    test('문장 속 6자리 코드(숫자 포함 대문자)', () {
      expect(inviteCodeIn('챌로리 초대코드 H3XK9P 로 들어와요'), 'H3XK9P');
      expect(inviteCodeIn('code: Q7W2E9.'), 'Q7W2E9');
    });
    test('코드가 아니면 null', () {
      expect(inviteCodeIn(null), isNull);
      expect(inviteCodeIn(''), isNull);
      expect(inviteCodeIn('안녕하세요'), isNull);
      expect(inviteCodeIn('ABC12'), isNull, reason: '5자리');
      expect(inviteCodeIn('ABCDEFG1'), isNull, reason: '8자리');
      expect(inviteCodeIn('오늘 HELLOS 봤어'), isNull, reason: '문장 속에서는 숫자가 있어야 코드');
      expect(inviteCodeIn('https://x.com/AB12CD9'), isNull);
    });
  });

  testWidgets('클립보드에 코드가 있으면 그 코드로 배너 → 붙여넣기', (tester) async {
    _clipboard(tester, 'H3XK9P');
    await _openCode(tester);
    expect(find.textContaining('복사한 초대코드 H3XK9P를 붙여넣을까요?'), findsOneWidget);
    expect(find.textContaining('K7Q2MD'), findsNothing);
    await tester.tap(find.text('붙여넣기'));
    await tester.pumpAndSettle();
    expect(find.text('H'), findsOneWidget, reason: '첫 칸');
    expect(find.text('P'), findsOneWidget, reason: '마지막 칸');
    expect(find.textContaining('복사한 초대코드'), findsNothing);
  });

  testWidgets('클립보드가 비었거나 코드가 아니면 배너 없음', (tester) async {
    _clipboard(tester, null);
    await _openCode(tester);
    expect(find.textContaining('복사한 초대코드'), findsNothing);
    expect(find.text('붙여넣기'), findsNothing);
  });

  testWidgets('코드가 아닌 글이면 배너 없음', (tester) async {
    _clipboard(tester, '점심 뭐 먹지');
    await _openCode(tester);
    expect(find.textContaining('복사한 초대코드'), findsNothing);
  });
}
