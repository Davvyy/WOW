// 오늘 활동(걸음) 상태: 서버 모드는 프로토타입 값(9,000보 · 삼성헬스 · 21:10)으로 시작하지 않는다.
// 건강 데이터를 못 읽으면(오류·빈 결과) 계속 비어 있고, 로그아웃·계정 전환이면 비운다. 홈 점수도 그 값(0걸음)을 쓴다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/services/health/health_models.dart';
import 'package:challory/services/health/health_source.dart';
import 'package:challory/services/health/mock_health_source.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Remote extends MockChalloryApi {
  @override
  bool get isRemote => true;
}

/// 건강 원천 흉내: [days] 를 돌려주거나 [error] 를 던진다
class _Health implements HealthSource {
  _Health({this.days = const [], this.error});
  List<HealthDay> days;
  Object? error;
  String label = 'Health Connect';
  @override
  String get platformLabel => label;
  @override
  Future<HealthAvailability> availability() async => HealthAvailability.ready;
  @override
  Future<PermissionResult> requestPermissions() async => PermissionResult.granted;
  @override
  Future<PermissionResult> permissionStatus() async => PermissionResult.granted;
  @override
  Future<List<HealthDay>> fetchDays({DateTime? now}) async {
    final e = error;
    if (e != null) throw e;
    return days;
  }
}

void _expectEmpty(TodayActivity a) {
  expect(a.stepsTotal, 0);
  expect(a.source, isEmpty, reason: '출처를 지어내지 않는다');
  expect(a.syncTime, isEmpty, reason: '동기화 시각을 지어내지 않는다');
  expect(a.sessions, isEmpty);
}

void main() {
  tearDown(resetSession);

  ProviderContainer remote({HealthSource? health, AuthService? auth}) {
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(_Remote()),
      authServiceProvider.overrideWithValue(auth ?? MockAuthService(true)),
      healthSourceProvider.overrideWithValue(health ?? const MockHealthSource()),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('서버 모드: 시작값은 비어 있다(0걸음 · 출처·동기화 시각 없음)', () {
    _expectEmpty(remote().read(activityProvider));
  });

  test('모의 모드: 프로토타입 활동 그대로', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(activityProvider).stepsTotal, mockTodayActivity.stepsTotal);
  });

  test('서버 모드: 건강 데이터를 못 읽으면(오류) 비어 있고 예외를 던지지 않는다', () async {
    final c = remote(health: _Health(error: StateError('Health Connect 없음')));
    expect(await c.read(activityProvider.notifier).refresh(), isFalse);
    _expectEmpty(c.read(activityProvider));
  });

  test('서버 모드: 읽은 날이 없으면 비어 있다', () async {
    final c = remote(health: _Health());
    expect(await c.read(activityProvider.notifier).refresh(), isFalse);
    _expectEmpty(c.read(activityProvider));
  });

  test('서버 모드: 읽었다가 다음 읽기에 실패하면 지난 값을 남기지 않는다', () async {
    final h = _Health(days: [HealthDay(localDate: '2026-10-13', stepsTotal: 8120)]);
    final c = remote(health: h);
    await c.read(activityProvider.notifier).refresh();
    expect(c.read(activityProvider).stepsTotal, 8120);
    h.error = StateError('권한 철회');
    expect(await c.read(activityProvider.notifier).refresh(), isFalse);
    _expectEmpty(c.read(activityProvider));
  });

  group('출처 이름(D77): 안드로이드를 모두 삼성헬스로 부르지 않는다', () {
    Future<String> sourceOf(List<HealthOrigin> sources, {String platform = 'Health Connect'}) async {
      final h = _Health(days: [HealthDay(localDate: '2026-10-13', stepsTotal: 5000, sources: sources)])..label = platform;
      final c = remote(health: h);
      await c.read(activityProvider.notifier).refresh();
      return c.read(activityProvider).source;
    }

    HealthOrigin o(String origin, int? steps, [RecordMethod m = RecordMethod.automatic]) => HealthOrigin(origin: origin, method: m, steps: steps);

    test('걸음이 가장 많은 출처의 앱 이름', () async {
      expect(await sourceOf([o('com.sec.android.app.shealth', 4000)]), '삼성헬스');
      expect(await sourceOf([o('com.android.healthconnect.phone.a1', 300), o('com.google.android.apps.fitness', 4700)]), 'Google 피트니스');
      expect(await sourceOf([o('com.android.healthconnect.phone.a1', 5000)]), '휴대폰 센서');
    });

    test('모르는 출처·출처 없음은 플랫폼 이름', () async {
      expect(await sourceOf([o('com.example.stepper', 5000)]), 'Health Connect');
      expect(await sourceOf(const []), 'Health Connect');
      expect(await sourceOf(const [], platform: 'Apple 건강'), 'Apple 건강');
    });

    test('수동 입력 출처는 이름으로 쓰지 않는다', () async {
      expect(await sourceOf([o('manual', 9000, RecordMethod.manual), o('com.sec.android.app.shealth', 1000)]), '삼성헬스');
    });
  });

  test('로그아웃하면 걸음을 비운다(다른 계정에 남지 않게)', () async {
    final auth = MockAuthService(true);
    final c = remote(health: _Health(days: [HealthDay(localDate: '2026-10-13', stepsTotal: 8120)]), auth: auth);
    c.listen(activityProvider, (_, _) {});
    await c.read(activityProvider.notifier).refresh();
    expect(c.read(activityProvider).stepsTotal, 8120);
    await auth.signOut();
    await Future<void>.delayed(Duration.zero);
    _expectEmpty(c.read(activityProvider));
  });

  test('서버 모드: 홈 점수(오늘 계산)는 0걸음으로 계산한다', () async {
    final c = remote();
    await c.read(sessionProvider.future);
    final sim = c.read(todayResultProvider);
    expect(sim.activity.aD, engine.simulate(SimulateInput(bmr: curMe.bmr, weightKg: curMe.weightKg)).activity.aD);
    expect(sim.activity.aD, isNot(engine.simulate(SimulateInput(bmr: curMe.bmr, weightKg: curMe.weightKg, stepsTotal: 9000)).activity.aD));
  });

  testWidgets('서버 모드 홈: 걸음을 못 읽었으면 "오늘 걸음을 못 읽었어요" · 동기화 시각을 지어내지 않는다', (tester) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = buildRouter(initialLocation: R.home);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiProvider.overrideWithValue(_Remote()), authServiceProvider.overrideWithValue(MockAuthService(true))],
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('오늘 걸음을 못 읽었어요'), findsWidgets);
    expect(find.textContaining('9,000'), findsNothing);
    expect(find.textContaining('21:10'), findsNothing);
  });
}
