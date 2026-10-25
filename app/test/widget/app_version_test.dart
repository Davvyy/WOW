// 앱 버전: 설정 맨 아래에 실제 버전(이름 + 빌드 번호), 알림 기기 등록에도 같은 값을 서버로
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/push/push_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/app_version.dart';
import 'package:challory/state/push_controller.dart';
import 'package:challory/state/session.dart';
import 'package:flutter/widgets.dart' show Scrollable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

void main() {
  tearDown(resetSession);

  testWidgets('설정 맨 아래: "챌로리 1.0.7 (8) · 모든 수치는 추정이에요"', (tester) async {
    await pumpApp(tester, location: R.settings, overrides: [appVersionProvider.overrideWithValue('1.0.7 (8)')]);
    await tester.scrollUntilVisible(find.textContaining('모든 수치는 추정이에요'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('챌로리 1.0.7 (8) · 모든 수치는 추정이에요'), findsOneWidget);
    expect(find.text('챌로리 1.0 · 모든 수치는 추정이에요'), findsNothing);
  });

  test('알림 기기 등록에 앱 버전을 함께 보낸다', () async {
    final api = MockChalloryApi();
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      pushServiceProvider.overrideWithValue(MockPushService(answer: PushPermission.granted)),
      deviceIdStoreProvider.overrideWithValue(MemoryDeviceIdStore()),
      appVersionProvider.overrideWithValue('1.0.7 (8)'),
    ]);
    addTearDown(c.dispose);
    await c.read(pushControllerProvider).enable();
    expect(api.devices.values.single.appVersion, '1.0.7 (8)');
  });
}
