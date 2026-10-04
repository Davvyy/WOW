import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';

import '../../core/engine/engine.dart';
import '../../core/format.dart';
import '../../data/models.dart';

/// 공유 카드 한 줄(음식명 · kcal)
class ShareLine {
  const ShareLine(this.name, this.kcal);
  final String name;
  final int kcal;
}

/// 식사 공유 카드에 들어가는 값. 닉네임·점수·순위·BMR·체중은 넣지 않는다(건강 정보는 밖으로 보내지 않음).
class MealShareData {
  const MealShareData({required this.title, required this.lines, required this.moreCount, required this.total, this.photo});

  /// 카드에 보이는 음식 줄 수(넘으면 "외 n개")
  static const maxLines = 5;

  /// "10.5 점심"
  final String title;
  final List<ShareLine> lines;
  final int moreCount;
  final int total;

  /// 공유용으로 보관한 사진(없으면 사진 없는 카드)
  final Uint8List? photo;

  factory MealShareData.fromRecord(MealRecord m, {required DateTime day, Uint8List? photo}) {
    final eaten = [for (final i in m.items.where((i) => i.checked)) ShareLine(i.name, i.kcal.round())];
    final all = eaten.isEmpty ? [ShareLine(m.title.isEmpty ? slotLabel[m.slot]! : m.title, m.kcal.round())] : eaten;
    return MealShareData(
      title: '${fmtMd(day)} ${slotLabel[m.slot]}',
      lines: all.take(maxLines).toList(),
      moreCount: all.length > maxLines ? all.length - maxLines : 0,
      total: m.kcal.round(),
      photo: photo,
    );
  }

  /// 공유 창에 함께 넘기는 문구
  String get caption => '$title · 약 ${fmtInt(total)} kcal #챌로리';
}

/// 사진의 가로÷세로 비율. 헤더만 읽어 빠르다(전체 디코딩 없음). 사진이 아니면 null.
double? photoAspectOf(Uint8List bytes) {
  try {
    final info = img.findDecoderForData(bytes)?.startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    return info.width / info.height;
  } catch (_) {
    return null;
  }
}

/// 사진을 보여 주는 칸의 비율: 사진 제 비율로 두되 세로 사진은 4:5, 가로 사진은 16:9 까지(너무 길거나 납작하지 않게)
double photoBoxAspect(Uint8List? bytes) => ((bytes == null ? null : photoAspectOf(bytes)) ?? 4 / 3).clamp(4 / 5, 16 / 9);

/// kcal 이 정해진 끼니(확정·자동 확정·정정)만 공유한다. AI 초안은 숫자가 바뀔 수 있어 제외.
bool canShareMeal(MealRecord m) =>
    m.kcal > 0 && const {MealStatus.confirmed, MealStatus.auto, MealStatus.corrected}.contains(m.status);

/// 공유 카드용 사진 보관소. 업로드용으로 이미 리사이즈·EXIF 제거된 JPEG 를 끼니 id 로 [maxAge] 동안 둔다.
abstract class SharePhotoStore {
  static const maxAge = Duration(days: 7);
  Future<void> put(String mealId, Uint8List bytes);
  Future<Uint8List?> get(String mealId);

  /// 끼니 하나의 사진을 지운다(기록을 지웠을 때)
  Future<void> remove(String mealId);

  /// 기간이 지난 사진을 지우고 지운 수를 돌려준다(앱 시작 시)
  Future<int> prune();

  /// 모두 지운다(로그아웃·계정 삭제)
  Future<void> clear();
}

class MemorySharePhotoStore implements SharePhotoStore {
  final photos = <String, Uint8List>{};
  @override
  Future<void> put(String mealId, Uint8List bytes) async => photos[mealId] = bytes;
  @override
  Future<Uint8List?> get(String mealId) async => photos[mealId];
  @override
  Future<void> remove(String mealId) async => photos.remove(mealId);
  @override
  Future<int> prune() async => 0;
  @override
  Future<void> clear() async => photos.clear();
}

/// 앱 전용 저장소(`application support/share_photos`)에 `{mealId}.jpg`. 사진첩에는 저장하지 않는다.
class FileSharePhotoStore implements SharePhotoStore {
  FileSharePhotoStore(Future<Directory> Function() resolveDir, {DateTime Function()? clock})
      : _resolve = resolveDir,
        _clock = clock ?? DateTime.now;
  FileSharePhotoStore.at(Directory d, {DateTime Function()? clock})
      : _resolve = (() async => d),
        _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _resolve;
  final DateTime Function() _clock;
  Directory? _dir;

  Future<Directory> _ready() async => _dir ??= await _resolve();

  /// 끼니 id 는 서버 uuid 지만 파일 이름으로 쓰기 전에 안전한 글자만 남긴다
  File _file(Directory d, String mealId) => File('${d.path}/${mealId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.jpg');

  bool _expired(File f) => _clock().difference(f.lastModifiedSync()) > SharePhotoStore.maxAge;

  @override
  Future<void> put(String mealId, Uint8List bytes) async {
    final d = await _ready();
    await d.create(recursive: true);
    await _file(d, mealId).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> get(String mealId) async {
    final f = _file(await _ready(), mealId);
    try {
      if (!await f.exists() || _expired(f)) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String mealId) async {
    final f = _file(await _ready(), mealId);
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  Future<int> prune() async {
    final d = await _ready();
    if (!await d.exists()) return 0;
    var n = 0;
    await for (final f in d.list()) {
      if (f is! File) continue;
      try {
        if (_expired(f)) {
          await f.delete();
          n++;
        }
      } catch (_) {}
    }
    return n;
  }

  @override
  Future<void> clear() async {
    final d = await _ready();
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}

/// 폰 기본 공유 창으로 이미지를 보낸다(인스타·카톡·문자 등 사용자가 고름)
abstract class MealSharer {
  Future<void> shareImage(Uint8List png, {required String fileName, required String text});
}

class SystemMealSharer implements MealSharer {
  const SystemMealSharer();
  @override
  Future<void> shareImage(Uint8List png, {required String fileName, required String text}) async {
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(png, mimeType: 'image/png', name: fileName)],
      fileNameOverrides: [fileName],
      text: text,
    ));
  }
}
