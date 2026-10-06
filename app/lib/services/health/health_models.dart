// 건강 데이터 일 집계 모델 (docs/05 §5 동기화 배치 포맷).
// 앱은 kcal 없이 "집계값·세션·출처"만 서버로 보낸다. 환산(MET)은 서버가 한다.

/// Asia/Seoul(UTC+9, 서머타임 없음) 기준 날짜 유틸. 전원 자정 anchor.
const kstOffset = Duration(hours: 9);

/// 인스턴트를 KST 벽시계 시각으로 바꾼 DateTime(UTC 플래그, 필드는 KST 값).
DateTime toKstWall(DateTime instant) => instant.toUtc().add(kstOffset);

/// KST 자정(해당 날짜 0시)의 실제 인스턴트(UTC).
DateTime kstMidnightInstant(int y, int m, int d) => DateTime.utc(y, m, d).subtract(kstOffset);

String kstDateString(DateTime kstWall) =>
    '${kstWall.year.toString().padLeft(4, '0')}-${kstWall.month.toString().padLeft(2, '0')}-${kstWall.day.toString().padLeft(2, '0')}';

/// ISO-8601 +09:00 표기.
String toKstIso(DateTime instant) {
  final w = toKstWall(instant);
  String p(int n, [int l = 2]) => n.toString().padLeft(l, '0');
  return '${p(w.year, 4)}-${p(w.month)}-${p(w.day)}T${p(w.hour)}:${p(w.minute)}:${p(w.second)}+09:00';
}

/// 기록 방식(05 sources[].method). 수동 입력은 집계에서 제외된다.
enum RecordMethod {
  automatic('AUTOMATICALLY_RECORDED'),
  active('ACTIVELY_RECORDED'),
  manual('MANUAL_ENTRY'),
  unknown('UNKNOWN');

  const RecordMethod(this.wire);
  final String wire;
}

/// 걸음 출처 하나. [steps]·[firstAt]·[lastAt] 은 그 출처 기록의 걸음 합계와 첫 시작·마지막 끝(있을 때만 보낸다).
/// 서버는 믿지 않는 출처의 검토(source_unknown) 상세에 이 값을 남긴다(D72).
class HealthOrigin {
  const HealthOrigin({required this.origin, required this.method, this.steps, this.firstAt, this.lastAt});
  final String origin;
  final RecordMethod method;
  final int? steps;
  final DateTime? firstAt;
  final DateTime? lastAt;

  Map<String, dynamic> toJson() => {
        'origin': origin,
        'method': method.wire,
        'steps': ?steps,
        if (firstAt != null) 'first_at': toKstIso(firstAt!),
        if (lastAt != null) 'last_at': toKstIso(lastAt!),
      };
}

/// 운동 세션(걷기·달리기·계단). 수동 입력 세션은 만들지 않는다.
class HealthSession {
  const HealthSession({
    required this.platformUid,
    required this.type,
    required this.start,
    required this.end,
    required this.distanceM,
    required this.stepsInRange,
    required this.origin,
    required this.method,
  });

  /// `hc:` + id (Health Connect) 또는 `hk:` + uuid (HealthKit)
  final String platformUid;

  /// running | stair | walking
  final String type;
  final DateTime start;
  final DateTime end;
  final double? distanceM;

  /// 세션 창 안의 걸음(서버가 일 걸음에서 차감해 이중 계산을 막는다)
  final int stepsInRange;
  final String origin;
  final RecordMethod method;

  Map<String, dynamic> toJson() => {
        'platform_uid': platformUid,
        'type': type,
        'start': toKstIso(start),
        'end': toKstIso(end),
        'distance_m': distanceM,
        'steps_in_range': stepsInRange,
        'origin': origin,
        'method': method.wire,
      };
}

/// 하루 집계. [platformActiveKcal] 은 P8 "참고값"으로만 보여주며 점수에는 쓰지 않는다.
class HealthDay {
  const HealthDay({
    required this.localDate,
    required this.stepsTotal,
    this.stepsManual,
    this.floors = 0,
    this.platformActiveKcal,
    this.hasManualSource = false,
    this.sources = const [],
    this.sessions = const [],
  });

  /// KST 날짜 yyyy-MM-dd
  final String localDate;

  /// iOS: 기록 걸음(수동 포함, 서버가 steps_manual 을 뺀다). Android: 수동 제외 집계.
  final int stepsTotal;

  /// iOS 만 값이 있다(WasUserEntered 집계). Android 는 null.
  final int? stepsManual;
  final int floors;

  /// 플랫폼 활동 칼로리(참고용). 순위 계산에 쓰지 않는다.
  final double? platformActiveKcal;
  final bool hasManualSource;
  final List<HealthOrigin> sources;
  final List<HealthSession> sessions;

  /// 순위에 반영되는 검증 걸음
  int get stepsVerified => stepsTotal - (stepsManual ?? 0);

  Map<String, dynamic> toJson() => {
        'local_date': localDate,
        'steps_total': stepsTotal,
        'steps_manual': stepsManual,
        'floors': floors,
        'platform_active_kcal': platformActiveKcal,
        'has_manual_source': hasManualSource,
        'sources': [for (final s in sources) s.toJson()],
        'sessions': [for (final s in sessions) s.toJson()],
      };
}

enum HealthAvailability {
  /// 사용 가능, 권한 확인 필요
  ready,

  /// Android 13 이하 등 Health Connect 앱 설치 필요
  needsInstall,

  /// 지원하지 않는 기기
  unsupported,

  /// 개발용 모의 데이터
  mock,
}

enum PermissionResult { granted, denied, notDetermined }
