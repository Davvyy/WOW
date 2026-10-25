// P12 닉네임 바꾸기(D81): 설정 닉네임 줄 → 창(지금 닉네임 · 글자 수 · 2~12자) → 저장하면 서버(set_my_nickname)에 보내고,
// 다시 시작하지 않아도 설정·순위·세션이 새 닉네임을 쓴다. 서버가 거절하면 창 안에 서버 문구를 보이고 닉네임은 그대로다.
// 입력 칸 컨트롤러는 창 안의 위젯이 가진다: 닫히는 애니메이션 동안에도 살아 있어야 한다(51020d9·31417b2 와 같은 문제).
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'screens_test.dart' show pumpApp;

/// 서버 모드처럼 보이는 모의 API(실제 사용자는 서버 모드)
class _Remote extends MockChalloryApi {
  @override
  bool get isRemote => true;
}

const _rowSub = '닉네임 · 순위에는 닉네임만 보여요';

Future<ProviderContainer> _open(WidgetTester tester, MockChalloryApi api) async {
  addTearDown(resetSession);
  return pumpApp(tester, location: R.settings, overrides: [
    apiProvider.overrideWithValue(api),
    authServiceProvider.overrideWithValue(MockAuthService(true)),
  ]);
}

Finder get _sheetField => find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField));
Finder get _save => find.widgetWithText(ChButton, '저장');
bool _saveEnabled(WidgetTester t) => t.widget<ChButton>(_save).onPressed != null;

Future<void> _openSheet(WidgetTester tester) async {
  final row = find.text(_rowSub);
  await tester.ensureVisible(row);
  await tester.tap(row);
  await tester.pumpAndSettle();
  expect(find.text('닉네임 바꾸기'), findsOneWidget);
}

/// 닫히는 애니메이션을 한 프레임씩 흘린다(그 사이 입력 칸이 다시 그려진다)
Future<void> _pumpClosing(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('닉네임 줄은 눌러서 바꿀 수 있다(화살표)', (tester) async {
    await _open(tester, _Remote());
    final nick = find.ancestor(of: find.text(_rowSub), matching: find.byType(InkWell));
    expect(nick.evaluate().any((e) => (e.widget as InkWell).onTap != null), isTrue);
    expect(find.descendant(of: nick.first, matching: find.byIcon(Icons.chevron_right_rounded)), findsOneWidget);
  });

  testWidgets('열기 → 고치기 → 저장: 서버에 보내고 설정·세션·순위가 새 닉네임', (tester) async {
    final api = _Remote();
    final c = await _open(tester, api);
    expect(find.text('지수'), findsOneWidget);
    await _openSheet(tester);
    // 지금 닉네임이 채워져 있고, 바꾸기 전에는 저장할 수 없다
    expect(tester.widget<TextField>(_sheetField).controller!.text, '지수');
    expect(find.text('2/12'), findsOneWidget);
    expect(_saveEnabled(tester), isFalse);

    await tester.enterText(_sheetField, '  새벽걷기  ');
    await tester.pump();
    expect(find.text('4/12'), findsOneWidget, reason: '앞뒤 공백은 세지 않는다');
    expect(_saveEnabled(tester), isTrue);
    await tester.tap(_save);
    await _pumpClosing(tester);
    expect(tester.takeException(), isNull);

    expect(api.calls, contains('set_my_nickname'));
    expect(api.nickname, '새벽걷기');
    expect(find.text('닉네임 바꾸기'), findsNothing);
    expect(find.text('닉네임을 바꿨어요'), findsOneWidget);
    expect(find.text('새벽걷기'), findsOneWidget);
    expect(find.text('지수'), findsNothing);
    // 세션(홈·순위가 읽는 값)도 바로 바뀐다: 모든 참가 챌린지
    expect(curMe.nickname, '새벽걷기');
    expect(c.read(sessionsProvider).value!.every((s) => s.me.nickname == '새벽걷기'), isTrue);

    // 순위 탭: 내 행이 새 닉네임
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(R.rank);
    await tester.pumpAndSettle();
    expect(find.textContaining('새벽걷기'), findsWidgets);
    expect(find.textContaining('지수'), findsNothing);
  });

  testWidgets('길이가 2~12자가 아니면 저장할 수 없다', (tester) async {
    await _open(tester, _Remote());
    await _openSheet(tester);
    await tester.enterText(_sheetField, '가');
    await tester.pump();
    expect(_saveEnabled(tester), isFalse);
    expect(find.text('1/12'), findsOneWidget);
    await tester.enterText(_sheetField, '    ');
    await tester.pump();
    expect(_saveEnabled(tester), isFalse);
    await tester.enterText(_sheetField, '가나');
    await tester.pump();
    expect(_saveEnabled(tester), isTrue);
    await tester.enterText(_sheetField, '가나다라마바사아자차카타파');
    await tester.pump();
    expect(tester.widget<TextField>(_sheetField).controller!.text.length, lessThanOrEqualTo(12), reason: '12자를 넘게 입력되지 않는다');
  });

  testWidgets('서버가 중복으로 거절하면 창 안에 서버 문구 · 닉네임은 그대로', (tester) async {
    final api = _Remote();
    final c = await _open(tester, api);
    await _openSheet(tester);
    await tester.enterText(_sheetField, '강남콩');
    await tester.pump();
    api.failNext = const ApiException(409, '이미 같은 챌린지에 있는 닉네임이에요');
    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('이미 같은 챌린지에 있는 닉네임이에요'), findsOneWidget);
    expect(find.text('닉네임 바꾸기'), findsOneWidget, reason: '창은 열린 채로 다시 고칠 수 있다');
    expect(curMe.nickname, '지수');
    expect(c.read(sessionsProvider).value!.every((s) => s.me.nickname == '지수'), isTrue);
    // 다시 고치면 문구가 사라진다
    await tester.enterText(_sheetField, '강남콩2');
    await tester.pump();
    expect(find.text('이미 같은 챌린지에 있는 닉네임이에요'), findsNothing);
  });

  testWidgets('취소 · 바깥 누르기로 닫아도 오류가 없고 닉네임은 그대로', (tester) async {
    final api = _Remote();
    await _open(tester, api);
    await _openSheet(tester);
    await tester.enterText(_sheetField, '바꿀까');
    await tester.tap(find.widgetWithText(ChButton, '취소'));
    await _pumpClosing(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('닉네임 바꾸기'), findsNothing);
    expect(find.text('지수'), findsOneWidget);

    await _openSheet(tester);
    await tester.enterText(_sheetField, '바꿀까');
    await tester.tapAt(const Offset(8, 8));
    await _pumpClosing(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('닉네임 바꾸기'), findsNothing);
    expect(api.calls, isNot(contains('set_my_nickname')));
    expect(curMe.nickname, '지수');
  });

  testWidgets('모의 모드도 같은 흐름: 모의 API 가 이름을 기억한다', (tester) async {
    final api = MockChalloryApi();
    addTearDown(resetSession);
    await pumpApp(tester, location: R.settings, overrides: [apiProvider.overrideWithValue(api)]);
    await _openSheet(tester);
    await tester.enterText(_sheetField, '모의이름');
    await tester.pump();
    await tester.tap(_save);
    await _pumpClosing(tester);
    expect(find.text('모의이름'), findsOneWidget);
    expect((await api.fetchSessions()).every((s) => s.me.nickname == '모의이름'), isTrue);
  });

  test('모의 API: 서버와 같은 길이·중복 규칙', () async {
    final api = MockChalloryApi();
    expect(await api.setNickname('  새이름 '), '새이름');
    await expectLater(api.setNickname('가'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 422)));
    await expectLater(api.setNickname('가나다라마바사아자차카타파'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 422)));
    // 모의 순위표의 다른 참가자 닉네임(대소문자 무시)
    await expectLater(api.setNickname('강남콩'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 409)));
    expect(await api.setNickname('새이름'), '새이름', reason: '지금 닉네임 그대로도 된다');
  });
}
