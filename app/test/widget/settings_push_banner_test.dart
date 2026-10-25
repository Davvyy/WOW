// 설정 상단 "알림이 꺼져 있어요" 배너: 거부뿐 아니라 아직 안 물어본 상태(재설치 직후 등)에도 보인다.
// 푸시를 쓸 수 없는 기기(서버·FCM 없음)와 이미 허용한 기기에는 없다.
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/push/push_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/push_controller.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

void main() {
  tearDown(resetSession);

  testWidgets('아직 안 물어봄: 배너 → "알림 켜기"로 허용하면 배너가 사라지고 기기가 등록된다', (tester) async {
    final api = MockChalloryApi();
    final push = MockPushService(answer: PushPermission.granted); // current = notAsked
    await pumpApp(tester, location: R.settings, overrides: [
      apiProvider.overrideWithValue(api),
      pushServiceProvider.overrideWithValue(push),
      deviceIdStoreProvider.overrideWithValue(MemoryDeviceIdStore()),
    ]);
    expect(find.textContaining('알림이 꺼져 있어요', findRichText: true), findsOneWidget);
    await tester.tap(find.text('알림 켜기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('알림이 꺼져 있어요', findRichText: true), findsNothing);
    expect(api.devices.values.single.permission, 'granted');
  });

  testWidgets('이미 허용: 배너 없음', (tester) async {
    final push = MockPushService()..current = PushPermission.granted;
    await pumpApp(tester, location: R.settings, overrides: [pushServiceProvider.overrideWithValue(push)]);
    expect(find.textContaining('알림이 꺼져 있어요', findRichText: true), findsNothing);
  });

  testWidgets('푸시를 쓸 수 없는 기기(모의·FCM 없음): 배너 없음', (tester) async {
    await pumpApp(tester, location: R.settings);
    expect(find.textContaining('알림이 꺼져 있어요', findRichText: true), findsNothing);
  });
}
