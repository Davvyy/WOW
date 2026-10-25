import 'dart:io';

import 'package:challory/services/health/health_models.dart';
import 'package:challory/services/health/health_package_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

/// Health Connect 를 흉내 낸다. 집계(includeManualEntry: true)는 중복 제거된 값([aggregate]),
/// 수동 제외 경로는 플러그인처럼 원본 기록을 그대로 더한 값([rawExcludingManual])을 돌려준다.
class _FakeHealth implements Health {
  _FakeHealth({required this.aggregate, required this.records});

  final int aggregate;
  final List<HealthDataPoint> records;

  /// 권한 요청·확인과 기록 읽기에 들어온 항목 전부
  final requested = <HealthDataType>[];
  final read = <HealthDataType>[];

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types, {List<HealthDataAccess>? permissions}) async {
    requested.addAll(types);
    return true;
  }

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types, {List<HealthDataAccess>? permissions}) async {
    requested.addAll(types);
    return true;
  }

  int get rawExcludingManual => records
      .where((p) => p.type == HealthDataType.STEPS && p.recordingMethod != RecordingMethod.manual)
      .fold(0, (a, p) => a + (p.value as NumericHealthValue).numericValue.toInt());

  @override
  Future<void> configure() async {}

  @override
  Future<int?> getTotalStepsInInterval(DateTime startTime, DateTime endTime, {bool includeManualEntry = true}) async =>
      includeManualEntry ? aggregate : rawExcludingManual;

  @override
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    Map<HealthDataType, HealthDataUnit>? preferredUnits,
    required DateTime startTime,
    required DateTime endTime,
    List<RecordingMethod> recordingMethodsToFilter = const [],
  }) async {
    read.addAll(types);
    return [
        for (final p in records)
          if (types.contains(p.type) && !recordingMethodsToFilter.contains(p.recordingMethod)) p,
      ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HealthDataPoint _steps(int count, String source, RecordingMethod method, {String? sourceName, DateTime? from, DateTime? to}) => HealthDataPoint(
      uuid: '$source-$count-${method.name}-${from?.hour}',
      value: NumericHealthValue(numericValue: count),
      type: HealthDataType.STEPS,
      unit: HealthDataUnit.COUNT,
      dateFrom: from ?? DateTime.utc(2026, 10, 3, 1),
      dateTo: to ?? DateTime.utc(2026, 10, 3, 2),
      sourcePlatform: HealthPlatformType.googleHealthConnect,
      sourceDeviceId: 'device',
      sourceId: source,
      sourceName: sourceName ?? source,
      recordingMethod: method,
    );

void main() {
  final now = DateTime.utc(2026, 10, 3, 5); // 14:00 KST

  group('Android 걸음(Health Connect)', () {
    test('여러 앱이 같은 걸음을 기록해도 중복 제거된 집계로 센다', () async {
      final health = _FakeHealth(aggregate: 28, records: [
        _steps(28, 'com.sec.android.app.shealth', RecordingMethod.automatic),
        _steps(8, 'com.google.android.apps.fitness', RecordingMethod.automatic),
      ]);
      final days = await HealthPackageSource(health: health, isAndroid: true).fetchDays(now: now);

      expect(days.first.stepsTotal, 28);
      expect(days.first.stepsManual, isNull);
      expect(days.first.hasManualSource, isFalse);
    });

    test('수동 입력은 집계에서 빼고 수동 출처로 표시한다', () async {
      final health = _FakeHealth(aggregate: 1000, records: [
        _steps(800, 'com.sec.android.app.shealth', RecordingMethod.automatic),
        _steps(200, 'com.sec.android.app.shealth', RecordingMethod.manual),
      ]);
      final days = await HealthPackageSource(health: health, isAndroid: true).fetchDays(now: now);

      expect(days.first.stepsTotal, 800);
      expect(days.first.hasManualSource, isTrue);
    });

    test('운동 세션 구간 걸음도 중복 제거된 집계로 센다', () async {
      final health = _FakeHealth(aggregate: 28, records: [
        _steps(28, 'com.sec.android.app.shealth', RecordingMethod.automatic),
        _steps(8, 'com.google.android.apps.fitness', RecordingMethod.automatic),
        HealthDataPoint(
          uuid: 'walk-1',
          value: WorkoutHealthValue(workoutActivityType: HealthWorkoutActivityType.WALKING),
          type: HealthDataType.WORKOUT,
          unit: HealthDataUnit.NO_UNIT,
          dateFrom: DateTime.utc(2026, 10, 3, 1),
          dateTo: DateTime.utc(2026, 10, 3, 2),
          sourcePlatform: HealthPlatformType.googleHealthConnect,
          sourceDeviceId: 'device',
          sourceId: 'com.sec.android.app.shealth',
          sourceName: 'Samsung Health',
          recordingMethod: RecordingMethod.automatic,
        ),
      ]);
      final days = await HealthPackageSource(health: health, isAndroid: true).fetchDays(now: now);

      expect(days.first.sessions.single.stepsInRange, 28);
    });

    test('걸음 기록의 sourceId 가 비어 있으면(플러그인 13.x) sourceName 의 패키지명을 출처로 쓴다', () async {
      final health = _FakeHealth(aggregate: 19, records: [
        _steps(19, '', RecordingMethod.automatic, sourceName: 'com.sec.android.app.shealth'),
      ]);
      final days = await HealthPackageSource(health: health, isAndroid: true).fetchDays(now: now);

      expect(days.first.sources.map((s) => s.origin), ['com.sec.android.app.shealth']);
      expect(days.first.sources.single.method, RecordMethod.automatic);
    });

    test('운동 세션 출처도 sourceId 가 비면 sourceName 을 쓴다', () async {
      final health = _FakeHealth(aggregate: 28, records: [
        _steps(28, 'com.sec.android.app.shealth', RecordingMethod.automatic),
        HealthDataPoint(
          uuid: 'walk-2',
          value: WorkoutHealthValue(workoutActivityType: HealthWorkoutActivityType.WALKING),
          type: HealthDataType.WORKOUT,
          unit: HealthDataUnit.NO_UNIT,
          dateFrom: DateTime.utc(2026, 10, 3, 1),
          dateTo: DateTime.utc(2026, 10, 3, 2),
          sourcePlatform: HealthPlatformType.googleHealthConnect,
          sourceDeviceId: 'device',
          sourceId: '',
          sourceName: 'com.sec.android.app.shealth',
          recordingMethod: RecordingMethod.automatic,
        ),
      ]);
      final days = await HealthPackageSource(health: health, isAndroid: true).fetchDays(now: now);

      expect(days.first.sessions.single.origin, 'com.sec.android.app.shealth');
    });

    test('출처마다 걸음 합계와 첫/마지막 기록 시각을 보낸다(D72)', () async {
      const phone = 'com.android.healthconnect.phone.a1b2';
      const shealth = 'com.sec.android.app.shealth';
      final health = _FakeHealth(aggregate: 5200, records: [
        _steps(1200, phone, RecordingMethod.automatic, from: DateTime.utc(2026, 10, 3, 0, 12), to: DateTime.utc(2026, 10, 3, 1)),
        _steps(2000, phone, RecordingMethod.automatic, from: DateTime.utc(2026, 10, 3, 3), to: DateTime.utc(2026, 10, 3, 4, 40)),
        _steps(2000, shealth, RecordingMethod.automatic, from: DateTime.utc(2026, 10, 3, 2), to: DateTime.utc(2026, 10, 3, 2, 30)),
      ]);
      final days = await HealthPackageSource(health: health, isAndroid: true).fetchDays(now: now);
      final json = {for (final s in days.first.sources) s.origin: s.toJson()};

      expect(json[phone], {
        'origin': phone,
        'method': 'AUTOMATICALLY_RECORDED',
        'steps': 3200,
        'first_at': '2026-10-03T09:12:00+09:00',
        'last_at': '2026-10-03T13:40:00+09:00',
      });
      expect(json[shealth]!['steps'], 2000);
      expect(json[shealth]!['first_at'], '2026-10-03T11:00:00+09:00');
      expect(json[shealth]!['last_at'], '2026-10-03T11:30:00+09:00');
    });
  });

  test('HealthOrigin: 걸음·시각이 없으면 origin·method 만', () {
    expect(const HealthOrigin(origin: 'x', method: RecordMethod.automatic).toJson(), {'origin': 'x', 'method': 'AUTOMATICALLY_RECORDED'});
  });

  group('읽는 항목은 P4 교육 카드 5개뿐(체중 없음)', () {
    const five = {
      HealthDataType.STEPS,
      HealthDataType.DISTANCE_DELTA,
      HealthDataType.FLIGHTS_CLIMBED,
      HealthDataType.WORKOUT,
      HealthDataType.ACTIVE_ENERGY_BURNED,
    };

    for (final android in [true, false]) {
      test('${android ? 'Android' : 'iOS'}: 권한 확인·요청·읽기에 체중이 없다', () async {
        final health = _FakeHealth(aggregate: 0, records: const []);
        final src = HealthPackageSource(health: health, isAndroid: android);
        await src.permissionStatus();
        await src.requestPermissions();
        await src.fetchDays(now: now);
        expect(health.requested.toSet(), five);
        expect(health.read, isNot(contains(HealthDataType.WEIGHT)));
        expect(five, containsAll(health.read.toSet()));
      });
    }

    test('AndroidManifest: 체중(READ_WEIGHT) 권한이 없고 읽기 권한은 5항목 + 백그라운드', () {
      final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final perms = RegExp(r'android\.permission\.health\.(\w+)').allMatches(xml).map((m) => m.group(1)).toSet();
      expect(perms, {
        'READ_STEPS',
        'READ_DISTANCE',
        'READ_FLOORS_CLIMBED',
        'READ_EXERCISE',
        'READ_ACTIVE_CALORIES_BURNED',
        'READ_HEALTH_DATA_IN_BACKGROUND',
      });
    });

    test('iOS 권한 안내 문구는 5항목만 말한다(체중 없음)', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(plist, isNot(contains('체중')));
      expect(plist, contains('걸음·거리·층수·운동 세션·활동 칼로리(참고)'));
    });
  });
}
