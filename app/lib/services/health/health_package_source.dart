import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

import 'health_models.dart';
import 'mock_health_source.dart';
import 'health_source.dart';

/// `health` 패키지(13.x) 구현. HealthKit / Health Connect 읽기 전용.
///
/// 원칙
///  - 합산은 플랫폼 집계 쿼리(getTotalStepsInInterval)만 쓴다. 샘플을 직접 더하는 경로는
///    수동 입력 식별(recordingMethod)과 층수·활동 칼로리 참고값에만 쓴다.
///  - 수동 입력(RecordingMethod.manual)은 걸음·세션에서 제외한다.
///    iOS: stepsTotal=기록(수동 포함), stepsManual=수동분 → 서버가 검증 걸음을 계산.
///    Android: Health Connect 집계는 수동분을 분리해 보고할 수 없으므로 stepsTotal=수동 제외 집계,
///    stepsManual=null, 수동 출처가 감지되면 hasManualSource=true(서버가 '검토 중' 플래그).
///  - 플랫폼 활동 칼로리는 [HealthDay.platformActiveKcal] 참고값으로만 전달한다.
class HealthPackageSource implements HealthSource {
  /// [isAndroid] 는 테스트에서 플랫폼 경로를 고르기 위한 것으로, 생략하면 실행 중인 플랫폼을 따른다.
  HealthPackageSource({Health? health, bool? isAndroid})
      : _health = health ?? Health(),
        _isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid);

  final Health _health;
  final bool _isAndroid;
  bool _configured = false;

  static const _types = <HealthDataType>[
    HealthDataType.STEPS,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.FLIGHTS_CLIMBED,
    HealthDataType.WORKOUT,
    HealthDataType.ACTIVE_ENERGY_BURNED,
  ];

  /// 모든 항목 읽기 전용(권한 시트 항목 = P4 교육 카드 5개)
  static final _access = List<HealthDataAccess>.filled(_types.length, HealthDataAccess.READ);

  /// 체중은 P12 "건강 앱에서 읽기" 최초 탭 시점에 별도 요청한다.
  static const weightType = HealthDataType.WEIGHT;

  @override
  String get platformLabel => _isAndroid ? 'Health Connect' : 'Apple 건강';

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  @override
  Future<HealthAvailability> availability() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return HealthAvailability.unsupported;
    await _ensureConfigured();
    if (_isAndroid && !await _health.isHealthConnectAvailable()) return HealthAvailability.needsInstall;
    return HealthAvailability.ready;
  }

  Future<void> installHealthConnect() => _health.installHealthConnect();

  @override
  Future<PermissionResult> permissionStatus() async {
    await _ensureConfigured();
    final ok = await _health.hasPermissions(_types, permissions: _access);
    // iOS 는 읽기 권한 여부를 알려주지 않는다(null). 읽어 보고 판단한다.
    if (ok == null) return PermissionResult.notDetermined;
    return ok ? PermissionResult.granted : PermissionResult.denied;
  }

  @override
  Future<PermissionResult> requestPermissions() async {
    await _ensureConfigured();
    final granted = await _health.requestAuthorization(_types, permissions: _access);
    return granted ? PermissionResult.granted : PermissionResult.denied;
  }

  /// P12 "건강 앱에서 읽기": 체중(bodyMass / WeightRecord) 별도 권한 후 최근 값 1건. 참고용·BMR 미반영.
  Future<double?> readLatestWeightKg({DateTime? now}) async {
    await _ensureConfigured();
    final ok = await _health.requestAuthorization([weightType], permissions: [HealthDataAccess.READ]);
    if (!ok) return null;
    final end = now ?? DateTime.now();
    final pts = await _health.getHealthDataFromTypes(
      types: [weightType],
      startTime: end.subtract(const Duration(days: 14)),
      endTime: end,
      recordingMethodsToFilter: const [],
    );
    if (pts.isEmpty) return null;
    pts.sort((a, b) => b.dateTo.compareTo(a.dateTo));
    final v = pts.first.value;
    return v is NumericHealthValue ? v.numericValue.toDouble() : null;
  }

  @override
  Future<List<HealthDay>> fetchDays({DateTime? now}) async {
    await _ensureConfigured();
    final instant = (now ?? DateTime.now()).toUtc();
    final w = toKstWall(instant);
    final days = <HealthDay>[];
    for (var i = 0; i < 3; i++) {
      final day = DateTime.utc(w.year, w.month, w.day).subtract(Duration(days: i));
      final start = kstMidnightInstant(day.year, day.month, day.day);
      final nextMidnight = start.add(const Duration(days: 1));
      // 오늘은 현재 시각까지만 조회(미래 구간 거부)
      final end = nextMidnight.isAfter(instant) ? instant : nextMidnight;
      days.add(await _fetchDay(kstDateString(day), start, end));
    }
    return days;
  }

  Future<HealthDay> _fetchDay(String localDate, DateTime start, DateTime end) async {
    // 1) 걸음: 수동 포함 집계 + 출처·수동 여부 식별용 샘플
    final recorded = await _health.getTotalStepsInInterval(start, end, includeManualEntry: true) ?? 0;
    final stepPts = await _safeRead([HealthDataType.STEPS], start, end);
    final verified = await _verifiedSteps(start, end, recorded, stepPts);
    final manualPart = (recorded - verified).clamp(0, recorded);

    // 2) 출처·수동 여부
    final origins = <String, RecordMethod>{};
    var manualSeen = manualPart > 0;
    for (final p in stepPts) {
      final m = _method(p.recordingMethod);
      if (m == RecordMethod.manual) manualSeen = true;
      // 같은 출처에 자동·수동이 섞이면 수동이 우선 표기된다.
      final origin = _origin(p);
      final prev = origins[origin];
      if (prev == null || m == RecordMethod.manual) origins[origin] = m;
    }

    // 3) 층수(수동 제외), 활동 칼로리(참고)
    final floorPts = await _safeRead([HealthDataType.FLIGHTS_CLIMBED], start, end, excludeManual: true);
    final floors = floorPts.fold<double>(0, (a, p) => a + _num(p.value)).round();
    final kcalPts = await _safeRead([HealthDataType.ACTIVE_ENERGY_BURNED], start, end, excludeManual: true);
    final activeKcal = kcalPts.isEmpty ? null : kcalPts.fold<double>(0, (a, p) => a + _num(p.value));

    // 4) 세션(수동 제외)
    final workouts = await _safeRead([HealthDataType.WORKOUT], start, end, excludeManual: true);
    final sessions = <HealthSession>[];
    for (final p in workouts) {
      final v = p.value;
      if (v is! WorkoutHealthValue) continue;
      final type = _sessionType(v.workoutActivityType);
      if (type == null) continue;
      final recordedInRange = await _health.getTotalStepsInInterval(p.dateFrom, p.dateTo, includeManualEntry: true) ?? 0;
      final inRange = await _verifiedSteps(p.dateFrom, p.dateTo, recordedInRange, [
        for (final s in stepPts)
          if (s.dateFrom.isBefore(p.dateTo) && s.dateTo.isAfter(p.dateFrom)) s,
      ]);
      sessions.add(HealthSession(
        platformUid: '${_isAndroid ? 'hc' : 'hk'}:${p.uuid}',
        type: type,
        start: p.dateFrom,
        end: p.dateTo,
        distanceM: v.totalDistance?.toDouble(),
        stepsInRange: inRange,
        origin: _origin(p),
        method: _method(p.recordingMethod),
      ));
    }

    return HealthDay(
      localDate: localDate,
      stepsTotal: _isAndroid ? verified : recorded,
      stepsManual: _isAndroid ? null : manualPart,
      floors: floors,
      platformActiveKcal: activeKcal,
      hasManualSource: manualSeen,
      sources: [for (final e in origins.entries) HealthOrigin(origin: e.key, method: e.value)],
      sessions: sessions,
    );
  }

  /// 수동 제외 걸음. Android(Health Connect)의 수동 제외 경로는 집계가 아니라 원본 기록 합이라
  /// 여러 앱이 같은 걸음을 쓰면 중복으로 센다. 그래서 중복 제거된 집계([recorded])에서 수동 입력 기록만 뺀다.
  /// iOS 는 HealthKit 통계 쿼리가 수동 제외 집계를 직접 돌려준다.
  Future<int> _verifiedSteps(DateTime start, DateTime end, int recorded, List<HealthDataPoint> stepPts) async {
    if (!_isAndroid) return await _health.getTotalStepsInInterval(start, end, includeManualEntry: false) ?? 0;
    final manual = stepPts
        .where((p) => p.recordingMethod == RecordingMethod.manual)
        .fold<double>(0, (a, p) => a + _num(p.value))
        .round();
    return (recorded - manual).clamp(0, recorded);
  }

  Future<List<HealthDataPoint>> _safeRead(List<HealthDataType> types, DateTime start, DateTime end, {bool excludeManual = false}) async {
    try {
      return await _health.getHealthDataFromTypes(
        types: types,
        startTime: start,
        endTime: end,
        recordingMethodsToFilter: excludeManual ? const [RecordingMethod.manual] : const [],
      );
    } catch (e) {
      debugPrint('health read failed for $types: $e');
      return const [];
    }
  }

  static double _num(HealthValue v) => v is NumericHealthValue ? v.numericValue.toDouble() : 0;

  /// 출처 패키지명. Android(health 13.x)는 걸음 기록의 sourceId 를 비우고 패키지명을 sourceName 에 넣는다.
  /// iOS 는 sourceId 가 번들 id 다.
  static String _origin(HealthDataPoint p) => p.sourceId.isNotEmpty ? p.sourceId : p.sourceName;

  static RecordMethod _method(RecordingMethod m) => switch (m) {
        RecordingMethod.automatic => RecordMethod.automatic,
        RecordingMethod.active => RecordMethod.active,
        RecordingMethod.manual => RecordMethod.manual,
        RecordingMethod.unknown => RecordMethod.unknown,
      };

  static String? _sessionType(HealthWorkoutActivityType t) => switch (t) {
        HealthWorkoutActivityType.RUNNING || HealthWorkoutActivityType.RUNNING_TREADMILL => 'running',
        HealthWorkoutActivityType.STAIR_CLIMBING || HealthWorkoutActivityType.STAIRS || HealthWorkoutActivityType.STAIR_CLIMBING_MACHINE => 'stair',
        HealthWorkoutActivityType.WALKING || HealthWorkoutActivityType.WALKING_TREADMILL || HealthWorkoutActivityType.HIKING => 'walking',
        _ => null,
      };
}

/// 실기기(Android/iOS)면 패키지 구현, 아니면 모의. `--dart-define=MOCK_HEALTH=true` 로 강제 모의.
HealthSource createHealthSource() {
  const forceMock = bool.fromEnvironment('MOCK_HEALTH');
  if (forceMock || kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return const MockHealthSource();
  return HealthPackageSource();
}
