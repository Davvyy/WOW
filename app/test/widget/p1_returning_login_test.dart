// P1: 이미 참가한 사용자는 챌린지를 고르지 않아도 바로 로그인해 홈으로(로그인이 풀린 뒤 다시 로그인).
// 참가 기록이 없으면 로그인 뒤 P1 에 머물며 챌린지를 고르라고 안내한다.
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

ChButton _kakao(WidgetTester t) => t.widget<ChButton>(find.byWidgetPredicate((w) => w is ChButton && w.label == '카카오로 계속하기'));

void main() {
  testWidgets('참가 중인 사용자: 챌린지를 고르지 않고 카카오 로그인 → 홈', (tester) async {
    final auth = MockAuthService();
    final api = MockChalloryApi()..participating = true;
    await pumpApp(tester, location: R.p1, overrides: [authServiceProvider.overrideWithValue(auth), apiProvider.overrideWithValue(api)]);
    expect(_kakao(tester).onPressed, isNotNull, reason: '챌린지를 고르기 전에도 로그인할 수 있다');
    await tester.tap(find.text('카카오로 계속하기'));
    await tester.pumpAndSettle();
    expect(auth.calls, ['kakao']);
    expect(find.text('카카오로 계속하기'), findsNothing, reason: '홈으로 이동');
  });

  testWidgets('참가 기록이 없으면 로그인 뒤 P1 에서 챌린지를 고르라고 안내', (tester) async {
    final auth = MockAuthService();
    final api = MockChalloryApi()..participating = false;
    await pumpApp(tester, location: R.p1, overrides: [authServiceProvider.overrideWithValue(auth), apiProvider.overrideWithValue(api)]);
    await tester.tap(find.text('카카오로 계속하기'));
    await tester.pumpAndSettle();
    expect(find.text('참가할 챌린지를 골라 주세요'), findsOneWidget);
    expect(find.text('이번 달 챌린지 참가하기'), findsOneWidget, reason: 'P1 에 머문다');
  });
}
