// 설정 화면(P12) 토글은 서버에 저장한다(D75): 시작할 때 서버 값을 읽고, 바꾸면 서버로 보내고, 실패하면 되돌린다.
// AI 사진 분석 동의는 철회·재동의 전에 확인 창을 띄운다(#5). 저장 기능이 없는 체중 기록·처리방침 줄은 숨긴다(#6·#24).
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

import 'screens_test.dart' show pumpApp;

class _Remote extends MockChalloryApi {
  _Remote(MySettings s) {
    settings = s;
  }
  @override
  bool get isRemote => true;
}

Finder _switch(String label) => find.byWidgetPredicate((w) => w is ChSwitch && w.label == label);
bool _on(WidgetTester t, String label) => t.widget<ChSwitch>(_switch(label)).value;

Future<ProviderContainer> _open(WidgetTester tester, MockChalloryApi api) async {
  addTearDown(resetSession);
  return pumpApp(tester, location: R.settings, overrides: [
    apiProvider.overrideWithValue(api),
    authServiceProvider.overrideWithValue(MockAuthService(true)),
  ]);
}

Future<void> _tapSwitch(WidgetTester tester, String label) async {
  await tester.ensureVisible(_switch(label));
  await tester.tap(_switch(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('서버 값으로 토글을 그린다(재시작·재설치 뒤에도 같은 값)', (tester) async {
    final api = _Remote(const MySettings(notifyYesterday: false, notifyReminder: true, notifyAnalysis: false, leaderboardVisible: false,
        gradeBadgePublic: true, aiConsent: false));
    final c = await _open(tester, api);
    expect(api.calls, contains('my_settings'));
    expect(_on(tester, '어제 결과'), isFalse);
    expect(_on(tester, '저녁 리마인드'), isTrue);
    expect(_on(tester, '분석 완료'), isFalse);
    expect(_on(tester, '순위에 내 행 보이기'), isFalse);
    expect(_on(tester, '측정 등급 배지 보이기'), isTrue);
    expect(find.text('AI 사진 분석 동의 철회됨'), findsOneWidget);
    // 다른 화면도 같은 값을 쓴다
    expect(c.read(rankVisibleProvider), isFalse);
    expect(c.read(aiConsentProvider), isFalse);
  });

  testWidgets('토글을 바꾸면 서버에 저장한다', (tester) async {
    final api = _Remote(const MySettings());
    final c = await _open(tester, api);
    await _tapSwitch(tester, '분석 완료');
    await _tapSwitch(tester, '저녁 리마인드');
    await _tapSwitch(tester, '어제 결과');
    await _tapSwitch(tester, '순위에 내 행 보이기');
    await _tapSwitch(tester, '측정 등급 배지 보이기');
    expect(api.settings.notifyAnalysis, isFalse);
    expect(api.settings.notifyReminder, isFalse);
    expect(api.settings.notifyYesterday, isFalse);
    expect(api.settings.leaderboardVisible, isFalse);
    expect(api.settings.gradeBadgePublic, isTrue);
    expect(c.read(rankVisibleProvider), isFalse);
    expect(_on(tester, '분석 완료'), isFalse);
  });

  testWidgets('저장에 실패하면 원래 값으로 되돌리고 안내한다', (tester) async {
    final api = _Remote(const MySettings());
    await _open(tester, api);
    api.failNext = const ApiException(0, 'offline');
    await _tapSwitch(tester, '분석 완료');
    expect(_on(tester, '분석 완료'), isTrue);
    expect(api.settings.notifyAnalysis, isTrue);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('AI 동의 철회: 확인 창 → 취소하면 그대로, 철회하면 서버에 저장', (tester) async {
    final api = _Remote(const MySettings(aiConsent: true));
    final c = await _open(tester, api);
    final row = find.text('AI 사진 분석 동의 철회');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('AI 사진 분석 동의를 철회할까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(api.settings.aiConsent, isTrue);
    expect(c.read(aiConsentProvider), isTrue);

    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChButton, '철회'));
    await tester.pumpAndSettle();
    expect(api.settings.aiConsent, isFalse);
    expect(c.read(aiConsentProvider), isFalse);
    expect(find.text('AI 사진 분석 동의 철회됨'), findsOneWidget);
  });

  testWidgets('AI 다시 동의: 확인 창을 거친다', (tester) async {
    final api = _Remote(const MySettings(aiConsent: false));
    await _open(tester, api);
    final row = find.text('AI 사진 분석 동의 철회됨');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('AI 사진 분석에 다시 동의할까요?'), findsOneWidget);
    expect(api.settings.aiConsent, isFalse, reason: '확인 전에는 바꾸지 않는다');
    await tester.tap(find.widgetWithText(ChButton, '동의'));
    await tester.pumpAndSettle();
    expect(api.settings.aiConsent, isTrue);
  });

  testWidgets('체중 기록(참고용) 카드·처리방침 줄은 없다 · 닉네임 줄은 눌리지 않는다', (tester) async {
    await _open(tester, _Remote(const MySettings()));
    expect(find.text('체중 기록 (참고용)'), findsNothing);
    expect(find.textContaining('69.4'), findsNothing);
    expect(find.textContaining('직접 입력 ·'), findsNothing);
    expect(find.text('건강 앱에서 읽기'), findsNothing);
    expect(find.textContaining(RegExp(r'시작 \d')), findsNothing);
    expect(find.text('개인정보 처리방침 · 이용약관'), findsNothing);
    final nick = find.ancestor(of: find.text('닉네임 · 순위에는 닉네임만 보여요'), matching: find.byType(InkWell));
    expect(nick.evaluate().every((e) => (e.widget as InkWell).onTap == null), isTrue);
  });

  testWidgets('모의 모드도 같은 화면으로 동작한다(기본값)', (tester) async {
    final api = MockChalloryApi();
    await pumpApp(tester, location: R.settings, overrides: [apiProvider.overrideWithValue(api)]);
    expect(_on(tester, '분석 완료'), isTrue);
    await _tapSwitch(tester, '분석 완료');
    expect(api.settings.notifyAnalysis, isFalse);
  });
}
