import 'dart:typed_data';

import '../api/challory_api.dart';
import '../health/health_source.dart' show newUuidV4;
import '../share/meal_share.dart';
import 'upload_queue_store.dart';

export 'upload_queue_store.dart' show PendingCapture, PendingStore, MemoryPendingStore, FilePendingStore;

/// 촬영 → 서버 끼니 생성 파이프라인(05 §6):
///   preparePhoto(리사이즈·EXIF 제거·SHA-256) → photo-upload-url → 서명 PUT → meals
/// 네트워크 단절·5xx 는 대기열에 넣고 같은 Idempotency-Key 로 다시 시도한다(재시도는 queued=true → 서버가 촬영 시각 기준 지연 업로드 규칙 적용).
/// 대기열은 [PendingStore](기본: 앱 전용 폴더 파일)에 저장돼 앱을 다시 켜도 이어서 보낸다.
class MealUploader {
  MealUploader(this.api, {this.prepare, PendingStore? store, this.shareStore, DateTime Function()? clock})
      : store = store ?? MemoryPendingStore(),
        _clock = clock ?? DateTime.now;

  final ChalloryApi api;
  final Future<PreparedPhoto> Function(Uint8List, DateTime)? prepare;
  final PendingStore store;

  /// 끼니가 만들어지면 공유 카드용으로 사진을 7일 보관한다(없으면 보관 안 함)
  final SharePhotoStore? shareStore;
  final DateTime Function() _clock;
  final List<PendingCapture> pending = [];
  bool _restored = false;

  /// 재시도 상한(05 §5 지수 백오프 5회 — 이후는 사용자가 새로고침할 때만)
  static const maxAttempts = 5;

  /// 대기열 보관 기간. 사진 원본은 챌린지 종료+7일에 파기되므로 그보다 오래 들고 있지 않는다.
  static const maxAge = Duration(days: 7);

  /// 저장된 대기열을 불러온다(앱 시작 시 1회). 오래된 건은 버린다.
  Future<List<PendingCapture>> restore() async {
    if (_restored) return List.of(pending);
    _restored = true;
    for (final job in await store.loadAll()) {
      if (_clock().toUtc().difference(job.queuedAt) > maxAge) {
        await store.remove(job);
        continue;
      }
      if (!pending.any((p) => p.id == job.id)) pending.add(job);
    }
    return List.of(pending);
  }

  /// [prepared] 를 서버에 올려 끼니를 만든다. 재시도할 수 있는 오류면 대기열에 넣고 null.
  /// [id] 는 대기열 작업 id(앱이 그 촬영 끼니를 가리키는 로컬 키, 없으면 업로드 키).
  Future<CreatedMeal?> submit(PreparedPhoto prepared, {String? localTag, String? id}) async {
    await restore();
    final job = PendingCapture(prepared, uploadKey: newUuidV4(), mealKey: newUuidV4(), localTag: localTag, queuedAt: _clock().toUtc(), id: id);
    return _run(job, queued: false);
  }

  Future<CreatedMeal?> submitRaw(Uint8List original, DateTime capturedAt, {String? localTag, String? id}) async {
    final prep = prepare;
    if (prep == null) throw StateError('prepare 함수가 없어요');
    return submit(await prep(original, capturedAt), localTag: localTag, id: id);
  }

  Future<CreatedMeal?> _run(PendingCapture job, {required bool queued, bool renewed = false}) async {
    try {
      job.ticket ??= await api.requestPhotoUpload(job.photo, idempotencyKey: job.uploadKey);
      if (!job.uploaded) {
        try {
          await api.uploadPhoto(job.ticket!, job.photo.bytes);
        } on ApiException catch (e) {
          // 저장해 둔 업로드 URL 이 만료됨(앱을 오래 꺼 둔 경우) → 새 키로 URL 을 한 번 다시 받는다
          if (!e.retryable && !renewed && job.ticket != null) {
            job.ticket = null;
            job.uploadKey = newUuidV4();
            return await _run(job, queued: queued, renewed: true);
          }
          rethrow;
        }
        job.uploaded = true;
        await _persistIfQueued(job);
      }
      // 촬영 화면에서 간식을 고른 경우만 서버에 알린다(D55). localTag 는 대기열에 저장돼 재시도에도 남는다.
      final meal = await api.createMeal(job.ticket!.photoId, queued: queued, idempotencyKey: job.mealKey,
          snack: job.localTag == 'snack');
      await _drop(job);
      try {
        await shareStore?.put(meal.mealId, job.photo.bytes);
      } catch (_) {} // 보관이 안 돼도 기록은 끝났다(공유 카드는 사진 없이 만든다)
      return meal;
    } on ApiException catch (e) {
      if (!e.retryable) {
        await _drop(job);
        rethrow;
      }
      job.attempts++;
      if (!pending.contains(job)) pending.add(job);
      await store.save(job);
      return null;
    }
  }

  Future<void> _persistIfQueued(PendingCapture job) async {
    if (pending.contains(job)) await store.save(job);
  }

  Future<void> _drop(PendingCapture job) async {
    pending.remove(job);
    await store.remove(job);
  }

  /// 앱 시작·복귀·당겨서 새로고침 때 호출. 성공한 끼니를 (localTag, meal, 작업 id) 로 돌려준다.
  /// [force] 면 재시도 상한을 넘은 것도 다시 보낸다(사용자가 직접 새로고침).
  Future<List<(String?, CreatedMeal, String)>> retryPending({bool force = false}) async {
    await restore();
    final done = <(String?, CreatedMeal, String)>[];
    for (final job in List.of(pending)) {
      if (!force && job.attempts >= maxAttempts) continue;
      if (!job.queuedKey) {
        job.mealKey = newUuidV4();
        job.queuedKey = true;
      }
      final m = await _run(job, queued: true);
      if (m != null) done.add((job.localTag, m, job.id));
    }
    return done;
  }
}
