import 'package:challory/services/health/health_package_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

/// Health Connect 를 흉내 낸다. 집계(includeManualEntry: true)는 중복 제거된 값([aggregate]),
/// 수동 제외 경로는 플러그인처럼 원본 기록을 그대로 더한 값([rawExcludingManual])을 돌려준다.
class _FakeHealth implements Health {
  _FakeHealth({required this.aggregate, required this.records});

  final int aggregate;
  final List<HealthDataPoint> records;

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
  }) async =>
      [
        for (final p in records)
          if (types.contains(p.type) && !recordingMethodsToFilter.contains(p.recordingMethod)) p,
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HealthDataPoint _steps(int count, String source, RecordingMethod method) => HealthDataPoint(
      uuid: '$source-$count-${method.name}',
      value: NumericHealthValue(numericValue: count),
      type: HealthDataType.STEPS,
      unit: HealthDataUnit.COUNT,
      dateFrom: DateTime.utc(2026, 10, 3, 1),
      dateTo: DateTime.utc(2026, 10, 3, 2),
      sourcePlatform: HealthPlatformType.googleHealthConnect,
      sourceDeviceId: 'device',
      sourceId: source,
      sourceName: source,
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
  });
}
