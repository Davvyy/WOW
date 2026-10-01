import 'dart:math';

import 'health_models.dart';

/// 건강 데이터 원천. 일 집계값만 돌려준다(원시 샘플 합산 금지).
abstract class HealthSource {
  /// 화면 표기용 플랫폼 이름 ("Health Connect" / "Apple 건강" / "모의 데이터")
  String get platformLabel;

  Future<HealthAvailability> availability();

  /// P4 교육 카드의 5개 항목(걸음·거리·층수·운동 세션·활동 칼로리)만 읽기 요청. 쓰기 권한은 요청하지 않는다.
  Future<PermissionResult> requestPermissions();

  Future<PermissionResult> permissionStatus();

  /// KST 기준 D, D−1, D−2 (최신순). [now] 는 테스트용.
  Future<List<HealthDay>> fetchDays({DateTime? now});
}

/// 05 §5 배치 포맷. client_batch_id 는 Idempotency-Key 로 쓴다.
Map<String, dynamic> buildSyncBatch(List<HealthDay> days, {String? clientBatchId}) => {
      'client_batch_id': clientBatchId ?? newUuidV4(),
      'tz': 'Asia/Seoul',
      'days': [for (final d in days) d.toJson()],
    };

/// D, D−1, D−2 의 KST 날짜 문자열(최신순)
List<String> kstWindowDates(DateTime now) {
  final w = toKstWall(now);
  return [
    for (var i = 0; i < 3; i++) kstDateString(DateTime.utc(w.year, w.month, w.day).subtract(Duration(days: i))),
  ];
}

String newUuidV4([Random? rng]) {
  final r = rng ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int v) => v.toRadixString(16).padLeft(2, '0');
  final s = b.map(h).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}
