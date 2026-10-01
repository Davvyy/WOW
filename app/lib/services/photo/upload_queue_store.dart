import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../api/challory_api.dart';

/// 업로드 대기 1건(사진 + 진행 상태). 같은 Idempotency-Key 로 이어서 보내기 위해 키·발급받은 업로드 URL 까지 저장한다.
class PendingCapture {
  PendingCapture(this.photo, {required this.uploadKey, required this.mealKey, this.localTag, DateTime? queuedAt, String? id})
      : queuedAt = queuedAt ?? DateTime.now().toUtc(),
        id = id ?? uploadKey;

  final PreparedPhoto photo;

  /// photo-upload-url 멱등 키. 업로드 URL 이 만료되면 새 키로 다시 받는다.
  String uploadKey;

  /// meals 멱등 키. 재시도(queued=true)로 본문이 바뀌면 새 키(서버 create_meal 이 photo_id 로 한 번 더 중복을 막음).
  String mealKey;
  final String? localTag;
  final DateTime queuedAt;
  PhotoUploadTicket? ticket;
  bool uploaded = false;
  int attempts = 0;
  bool queuedKey = false;

  /// 저장 파일 이름(처음 업로드 키로 정하고, 키가 바뀌어도 그대로)
  final String id;

  Map<String, dynamic> toJson() => {
        'id': id,
        'upload_key': uploadKey,
        'meal_key': mealKey,
        'local_tag': localTag,
        'queued_at': queuedAt.toIso8601String(),
        'sha256': photo.sha256,
        'width': photo.width,
        'height': photo.height,
        'captured_at': photo.capturedAt.toUtc().toIso8601String(),
        'uploaded': uploaded,
        'attempts': attempts,
        'queued_key': queuedKey,
        if (ticket != null) 'ticket': {'photo_id': ticket!.photoId, 'storage_path': ticket!.storagePath, 'token': ticket!.token},
      };

  static PendingCapture fromJson(Map<String, dynamic> j, Uint8List bytes) {
    final t = j['ticket'] as Map?;
    final job = PendingCapture(
      PreparedPhoto(
        bytes: bytes,
        sha256: j['sha256'] as String,
        width: (j['width'] as num).toInt(),
        height: (j['height'] as num).toInt(),
        capturedAt: DateTime.parse(j['captured_at'] as String),
      ),
      uploadKey: j['upload_key'] as String,
      mealKey: j['meal_key'] as String,
      localTag: j['local_tag'] as String?,
      queuedAt: DateTime.parse(j['queued_at'] as String),
      id: j['id'] as String?,
    )
      ..uploaded = j['uploaded'] as bool? ?? false
      ..attempts = (j['attempts'] as num?)?.toInt() ?? 0
      ..queuedKey = j['queued_key'] as bool? ?? false
      ..ticket = t == null ? null : PhotoUploadTicket(photoId: t['photo_id'] as String, storagePath: t['storage_path'] as String, token: t['token'] as String);
    return job;
  }
}

/// 대기열 저장소. 앱 종료·재시작 뒤에도 이어서 보내기 위해 사진(이미 리사이즈·EXIF 제거된 JPEG)과 상태를 보관한다.
abstract class PendingStore {
  Future<List<PendingCapture>> loadAll();
  Future<void> save(PendingCapture job);
  Future<void> remove(PendingCapture job);
}

class MemoryPendingStore implements PendingStore {
  final jobs = <String, PendingCapture>{};
  @override
  Future<List<PendingCapture>> loadAll() async => jobs.values.toList();
  @override
  Future<void> save(PendingCapture job) async => jobs[job.id] = job;
  @override
  Future<void> remove(PendingCapture job) async => jobs.remove(job.id);
}

/// 앱 전용 저장소(`application support/upload_queue`)에 `{id}.jpg` + `{id}.json`.
/// 사진첩·공유 폴더가 아니며, 업로드가 끝나거나 버려지면 바로 지운다. 망가진 파일은 건너뛰고 지운다.
class FilePendingStore implements PendingStore {
  /// [resolveDir] 는 처음 쓸 때 한 번 부른다(path_provider 는 비동기).
  FilePendingStore(Future<Directory> Function() resolveDir) : _resolve = resolveDir;
  FilePendingStore.at(Directory d) : _resolve = (() async => d);

  final Future<Directory> Function() _resolve;
  Directory? _dir;
  Directory get dir => _dir!;

  Future<void> _ready() async => _dir ??= await _resolve();

  File _json(String id) => File('${dir.path}/$id.json');
  File _jpg(String id) => File('${dir.path}/$id.jpg');

  @override
  Future<List<PendingCapture>> loadAll() async {
    await _ready();
    if (!await dir.exists()) return [];
    final out = <PendingCapture>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final id = f.uri.pathSegments.last.replaceAll('.json', '');
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final bytes = await _jpg(id).readAsBytes();
        out.add(PendingCapture.fromJson(j, bytes));
      } catch (_) {
        await _delete(id);
      }
    }
    out.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return out;
  }

  @override
  Future<void> save(PendingCapture job) async {
    await _ready();
    await dir.create(recursive: true);
    final jpg = _jpg(job.id);
    if (!await jpg.exists()) await jpg.writeAsBytes(job.photo.bytes, flush: true);
    // 쓰기 도중 종료돼도 이전 상태가 남도록 임시 파일 → 이름 바꾸기
    final tmp = File('${dir.path}/${job.id}.json.tmp');
    await tmp.writeAsString(jsonEncode(job.toJson()), flush: true);
    await tmp.rename(_json(job.id).path);
  }

  @override
  Future<void> remove(PendingCapture job) async {
    await _ready();
    await _delete(job.id);
  }

  Future<void> _delete(String id) async {
    for (final f in [_json(id), _jpg(id), File('${dir.path}/$id.json.tmp')]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
