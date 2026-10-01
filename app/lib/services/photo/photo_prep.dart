import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../api/challory_api.dart';

/// 촬영 원본 → 업로드용 사진(05 §6): 방향 반영 → 긴 변 ≤1,568 px 리사이즈 → EXIF(GPS 포함) 제거 → JPEG 재인코딩 → SHA-256.
/// 무거운 작업이라 별도 isolate 에서 돌린다.
Future<PreparedPhoto> preparePhoto(Uint8List original, DateTime capturedAt) async {
  final r = await compute(_prepare, original);
  return PreparedPhoto(bytes: r.bytes, sha256: r.sha, width: r.w, height: r.h, capturedAt: capturedAt);
}

class _Prepared {
  const _Prepared(this.bytes, this.sha, this.w, this.h);
  final Uint8List bytes;
  final String sha;
  final int w;
  final int h;
}

const maxLongEdge = 1568;

_Prepared _prepare(Uint8List original) => _prepareSync(original);

_Prepared _prepareSync(Uint8List original) {
  final decoded = img.decodeImage(original);
  if (decoded == null) throw const ApiException(422, '사진을 읽을 수 없어요');
  var image = img.bakeOrientation(decoded);
  final long = image.width > image.height ? image.width : image.height;
  if (long > maxLongEdge) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxLongEdge, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: maxLongEdge, interpolation: img.Interpolation.average);
  }
  image.exif = img.ExifData(); // EXIF 전부 제거(GPS 미수집)
  final out = Uint8List.fromList(img.encodeJpg(image, quality: 82));
  return _Prepared(out, crypto.sha256.convert(out).toString(), image.width, image.height);
}

/// 테스트 접근용
({Uint8List bytes, String sha, int w, int h}) preparePhotoSync(Uint8List original) {
  final p = _prepareSync(original);
  return (bytes: p.bytes, sha: p.sha, w: p.w, h: p.h);
}
