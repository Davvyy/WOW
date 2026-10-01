import 'dart:typed_data';

import '../api/challory_api.dart';
import '../health/health_source.dart' show newUuidV4;

/// 촬영 → 서버 끼니 생성 파이프라인(05 §6):
///   preparePhoto(리사이즈·EXIF 제거·SHA-256) → photo-upload-url → 서명 PUT → meals
/// 네트워크 단절·5xx 는 [pending] 큐에 넣고 같은 Idempotency-Key 로 다시 시도한다(재시도 시 queued=true → 서버가 촬영 시각으로 태그).
/// 큐는 메모리에만 있다(앱 종료 시 사라짐 — 디스크 보관은 남은 일).
class MealUploader {
  MealUploader(this.api, {this.prepare});

  final ChalloryApi api;
  final Future<PreparedPhoto> Function(Uint8List, DateTime)? prepare;
  final List<PendingCapture> pending = [];

  /// [prepared] 를 서버에 올려 끼니를 만든다. 재시도할 수 있는 오류면 큐에 넣고 null.
  Future<CreatedMeal?> submit(PreparedPhoto prepared, {String? localTag}) async {
    final job = PendingCapture(prepared, uploadKey: newUuidV4(), mealKey: newUuidV4(), localTag: localTag);
    return _run(job, queued: false);
  }

  Future<CreatedMeal?> submitRaw(Uint8List original, DateTime capturedAt, {String? localTag}) async {
    final prep = prepare;
    if (prep == null) throw StateError('prepare 함수가 없어요');
    return submit(await prep(original, capturedAt), localTag: localTag);
  }

  Future<CreatedMeal?> _run(PendingCapture job, {required bool queued}) async {
    try {
      job.ticket ??= await api.requestPhotoUpload(job.photo, idempotencyKey: job.uploadKey);
      if (!job.uploaded) {
        await api.uploadPhoto(job.ticket!, job.photo.bytes);
        job.uploaded = true;
      }
      final meal = await api.createMeal(job.ticket!.photoId, queued: queued, idempotencyKey: job.mealKey);
      pending.remove(job);
      return meal;
    } on ApiException catch (e) {
      if (!e.retryable) {
        pending.remove(job);
        rethrow;
      }
      if (!pending.contains(job)) pending.add(job);
      job.attempts++;
      return null;
    }
  }

  /// 앱 복귀·당겨서 새로고침 때 호출. 성공한 끼니를 (localTag, meal) 로 돌려준다.
  Future<List<(String?, CreatedMeal)>> retryPending() async {
    final done = <(String?, CreatedMeal)>[];
    for (final job in List.of(pending)) {
      if (job.attempts >= 5) continue; // 05 §5 지수 백오프 5회 — 이후는 수동 재시도
      if (!job.queuedKey) {
        job.mealKey = newUuidV4();
        job.queuedKey = true;
      }
      final m = await _run(job, queued: true);
      if (m != null) done.add((job.localTag, m));
    }
    return done;
  }
}

class PendingCapture {
  PendingCapture(this.photo, {required this.uploadKey, required this.mealKey, this.localTag});
  final PreparedPhoto photo;
  final String uploadKey;
  /// 재시도(queued=true)로 본문이 바뀌면 새 키를 쓴다. 서버 create_meal 이 photo_id 로 한 번 더 중복을 막는다.
  String mealKey;
  final String? localTag;
  PhotoUploadTicket? ticket;
  bool uploaded = false;
  int attempts = 0;
  bool queuedKey = false;
}
