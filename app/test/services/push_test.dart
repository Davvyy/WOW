// 푸시: 기기 등록(권한·토큰) · N-04 분석 완료 → 초안 갱신 · 로그아웃 해제
import 'package:challory/app.dart';
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart' show mockAiTotal;
import 'package:challory/data/models.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/push/push_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/push_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

PushMessage n04(String mealId, [MealSlot slot = MealSlot.lunch]) =>
    PushMessage(data: {'type': 'N-04', 'id': 'n1', 'meal_id': mealId, 'slot': slot.name}, title: '분석 완료', body: '점심 분석이 끝났어요');

void main() {
  late MockChalloryApi api;
  late MockPushService push;
  late ProviderContainer c;

  setUp(() {
    // 12:20 KST → 서버 슬롯 점심, 분석은 바로 끝난 것으로
    api = MockChalloryApi(analysisDelay: Duration.zero, clock: () => DateTime.utc(2026, 10, 13, 3, 20));
    push = MockPushService(answer: PushPermission.granted);
    c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      pushServiceProvider.overrideWithValue(push),
      deviceIdStoreProvider.overrideWithValue(MemoryDeviceIdStore()),
    ]);
    c.read(mealsProvider.notifier).reset([for (final s in MealSlot.values) MealRecord(slot: s)]);
  });
  tearDown(() => c.dispose());

  test('권한 전: 시작해도 등록 안 함 → "알림 켜기"로 허용 → 토큰 등록 → 토큰 갱신은 같은 기기 행', () async {
    final ctl = c.read(pushControllerProvider);
    await ctl.start();
    expect(api.devices, isEmpty);
    expect(await ctl.enable(), PushPermission.granted);
    expect(api.devices.values.single.token, 'mock-token');
    expect(api.devices.values.single.permission, 'granted');
    final id = api.devices.keys.single;
    push.rotateToken('tok-2');
    await pumpEventQueue();
    expect(api.devices.keys, [id]);
    expect(api.devices[id]!.token, 'tok-2');
  });

  test('거부하면 토큰 없이 denied 로 남김(서버는 N-04 를 no_push 로 건너뜀)', () async {
    push.answer = PushPermission.denied;
    expect(await c.read(pushControllerProvider).enable(), PushPermission.denied);
    expect(api.devices.values.single.token, isNull);
    expect(api.devices.values.single.permission, 'denied');
  });

  test('앱을 보고 있을 때 N-04 → 그 끼니를 다시 읽어 초안(확인 필요)으로 + 안내', () async {
    final meal = await api.createMeal('photo-1', queued: false, idempotencyKey: 'k');
    final n = c.read(mealsProvider.notifier);
    n.reset([for (final s in MealSlot.values) s == meal.slot ? MealRecord(slot: s, status: MealStatus.captured, serverId: meal.mealId) : MealRecord(slot: s)]);
    final ctl = c.read(pushControllerProvider);
    final ready = ctl.draftReady.first;
    push.current = PushPermission.granted;
    await ctl.start();
    push.emitForeground(n04(meal.mealId));
    final d = await ready;
    expect(d.slot, MealSlot.lunch);
    expect(d.opened, isFalse);
    final lunch = n.of(MealSlot.lunch);
    expect(lunch.status, MealStatus.draft);
    expect(lunch.items, isNotEmpty);
    expect(lunch.aiKcal, mockAiTotal(MealSlot.lunch));
  });

  test('앱이 꺼져 있다가 알림을 눌러 실행 → 시작할 때 그 끼니로(opened)', () async {
    push
      ..current = PushPermission.granted
      ..launch = n04('meal-unknown', MealSlot.dinner);
    final ctl = c.read(pushControllerProvider);
    final ready = ctl.draftReady.first;
    await ctl.start();
    final d = await ready;
    expect(d.slot, MealSlot.dinner);
    expect(d.opened, isTrue);
    expect(api.devices.values.single.token, 'mock-token', reason: '이미 허용 → 시작 때 등록');
  });

  test('N-04 가 아닌 푸시(공지 등)는 끼니를 건드리지 않음', () async {
    final ctl = c.read(pushControllerProvider);
    await ctl.start();
    await ctl.handle(const PushMessage(data: {'type': 'N-03', 'id': 'x'}), opened: false);
    expect(api.calls.where((x) => x == 'fetchMeal'), isEmpty);
  });

  test('로그아웃: 기기 행을 지우고 저장한 id 도 비움 · 다시 시작 가능', () async {
    final ctl = c.read(pushControllerProvider);
    await ctl.enable();
    expect(api.devices, hasLength(1));
    await ctl.stop();
    expect(api.devices, isEmpty);
    expect(await c.read(deviceIdStoreProvider).read(), isNull);
    expect(ctl.started, isFalse);
  });

  testWidgets('앱 셸: 화면에 떠 있을 때 받은 N-04 는 "점심 분석이 끝났어요 · 확인하기" 안내', (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const ChalloryApp()));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await c.read(pushControllerProvider).handle(n04('meal-x'), opened: false);
    });
    await tester.pump();
    expect(find.text('점심 분석이 끝났어요'), findsOneWidget);
    expect(find.text('확인하기'), findsOneWidget);
  });
}
