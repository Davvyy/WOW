import 'dart:convert';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nonce: 제공자에는 SHA-256, Supabase 에는 원본', () {
    final n = newNonce();
    expect(n.raw.length, 32);
    expect(n.hashed, crypto.sha256.convert(utf8.encode(n.raw)).toString());
    expect(newNonce().raw, isNot(n.raw));
  });

  group('온보딩 → join_challenge', () {
    late MockChalloryApi api;
    late ProviderContainer c;
    setUp(() {
      api = MockChalloryApi();
      c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    });
    tearDown(() => c.dispose());

    Future<String?> run(String code, {double weight = 70, int birth = 1996, bool terms = true}) async {
      final n = c.read(onboardingProvider.notifier);
      n.setInvite(code, await api.getInvite(code));
      n.setProfile(nickname: ' 지수 ', sex: Sex.m, birthYear: birth, heightCm: 175, weightKg: weight, pregnancy: false,
          eatingDisorder: false, sensitiveHealth: true);
      return n.join(terms: terms, overseasAi: true);
    }

    test('정상 참가: 서버 BMR 잠금(1,650) · 닉네임 공백 제거 · 동의 전달', () async {
      expect(await run('K7Q2MD'), isNull);
      final d = c.read(onboardingProvider);
      expect(d.join!.bmr, 1650);
      expect(d.join!.recordMode, isFalse);
      expect(api.lastJoin!.nickname, '지수');
      expect(api.lastJoin!.toJson()['consents'], {'terms': true, 'sensitive_health': true, 'overseas_ai': true});
    });
    test('BMI < 18.5 → 기록 모드', () async {
      expect(await run('K7Q2MD', weight: 50), isNull);
      expect(c.read(onboardingProvider).join!.recordMode, isTrue);
    });
    test('재가입 차단 코드 → 서버 거절 문구(사유 미노출)', () async {
      expect(await run('BLOCK0'), '참가할 수 없는 챌린지예요');
    });
    test('만 14세 미만 → 참가 불가', () async {
      expect(await run('K7Q2MD', birth: 2013), '만 14세 이상부터 참가할 수 있어요');
    });
    test('초대코드: 없는 코드 null · 정원 초과 full', () async {
      expect(await api.getInvite('ZZZZZZ'), isNull);
      expect((await api.getInvite('FULL00'))!.full, isTrue);
    });
  });

  group('로그인 가드(서버 모드)', () {
    testWidgets('로그인 전에는 P1 으로, 로그인하면 열림 · 로그아웃하면 다시 P1', (tester) async {
      final auth = MockAuthService();
      final router = buildRouter(initialLocation: R.settings, auth: auth);
      addTearDown(router.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [authServiceProvider.overrideWithValue(auth)],
        child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
      ));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, R.p1);
      await auth.signInWithKakao();
      router.go(R.settings);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, R.settings);
      await auth.signOut();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, R.p1);
    });
  });

  testWidgets('P1: 코드 확인 → 카카오 로그인 → P2(닉네임 미리 채움)', (tester) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = MockAuthService();
    final api = MockChalloryApi();
    final router = buildRouter(initialLocation: R.p1);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [authServiceProvider.overrideWithValue(auth), apiProvider.overrideWithValue(api)],
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('초대코드가 있어요'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'k7q2md');
    await tester.pumpAndSettle();
    expect(api.calls, contains('get_invite'));
    expect(find.text('가을 걷기 챌린지'), findsOneWidget);
    await tester.tap(find.text('카카오로 계속하기'));
    await tester.pumpAndSettle();
    expect(auth.calls, ['kakao']);
    expect(router.state.uri.path, R.p2);
    expect(find.widgetWithText(TextField, '지수'), findsWidgets);
  });

  testWidgets('P1: 이번 달 챌린지 참가하기 → 카카오 로그인 → P2(코드 없이 월간 표시 유지)', (tester) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = MockAuthService();
    final api = MockChalloryApi();
    final router = buildRouter(initialLocation: R.p1);
    addTearDown(router.dispose);
    late ProviderContainer c;
    await tester.pumpWidget(ProviderScope(
      overrides: [authServiceProvider.overrideWithValue(auth), apiProvider.overrideWithValue(api)],
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    c = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    // 로그인 버튼은 고르기 전에도 켜져 있다(이미 참가한 사용자의 재로그인). 여기서는 먼저 고르고 로그인한다.
    await tester.tap(find.text('이번 달 챌린지 참가하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('카카오로 계속하기'));
    await tester.pumpAndSettle();
    expect(auth.calls, ['kakao']);
    expect(router.state.uri.path, R.p2);
    expect(c.read(onboardingProvider).monthly, isTrue);
    expect(c.read(onboardingProvider).nickname, '지수');
  });

  testWidgets('P1: 이미 참가 중이면 로그인 뒤 홈', (tester) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = MockChalloryApi()..participating = true;
    final router = buildRouter(initialLocation: R.p1);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [authServiceProvider.overrideWithValue(MockAuthService()), apiProvider.overrideWithValue(api)],
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('초대코드가 있어요'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'K7Q2MD');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple로 계속하기'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, R.home);
  });
}
