// 식사 공유: 카드 데이터(먹은 항목·합계만) · 공유용 사진 7일 보관 · 업로드 성공 시 보관
import 'dart:io';
import 'dart:typed_data';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/photo/meal_uploader.dart';
import 'package:challory/services/share/meal_share.dart';
import 'package:flutter_test/flutter_test.dart';

MealItem item(String name, int kcal, {bool checked = true}) =>
    MealItem(id: name, candidates: [name], candKcal: [kcal], portion: '1인분', kind: ItemKind.count, checked: checked);

void main() {
  group('MealShareData', () {
    test('먹은 항목만 · kcal 반올림 · 합계는 확정 kcal', () {
      final m = MealRecord(
        slot: MealSlot.lunch,
        status: MealStatus.confirmed,
        kcal: 680,
        items: [item('비빔밥', 560), item('김', 70, checked: false), item('된장국', 120)],
      );
      final d = MealShareData.fromRecord(m, day: DateTime(2026, 10, 5));
      expect(d.title, '10.5 점심');
      expect(d.lines.map((l) => (l.name, l.kcal)), [('비빔밥', 560), ('된장국', 120)]);
      expect(d.moreCount, 0);
      expect(d.total, 680);
      expect(d.caption, '10.5 점심 · 약 680 kcal #챌로리');
    });

    test('항목이 6개 이상이면 5개까지 보이고 나머지는 "외 n개"', () {
      final m = MealRecord(
        slot: MealSlot.dinner,
        status: MealStatus.auto,
        kcal: 900,
        items: [for (var i = 0; i < 7; i++) item('반찬$i', 100)],
      );
      final d = MealShareData.fromRecord(m, day: DateTime(2026, 10, 5));
      expect(d.lines.length, MealShareData.maxLines);
      expect(d.moreCount, 2);
    });

    test('항목이 없으면 끼니 제목 한 줄', () {
      const m = MealRecord(slot: MealSlot.breakfast, status: MealStatus.confirmed, kcal: 420, title: '토스트·우유');
      final d = MealShareData.fromRecord(m, day: DateTime(2026, 10, 5));
      expect(d.lines.map((l) => (l.name, l.kcal)), [('토스트·우유', 420)]);
    });

    test('확정·자동 확정·정정만 공유할 수 있다', () {
      for (final s in MealStatus.values) {
        final ok = canShareMeal(MealRecord(slot: MealSlot.lunch, status: s, kcal: 500));
        expect(ok, {MealStatus.confirmed, MealStatus.auto, MealStatus.corrected}.contains(s), reason: s.name);
      }
      expect(canShareMeal(const MealRecord(slot: MealSlot.lunch, status: MealStatus.confirmed)), isFalse, reason: '0 kcal');
    });
  });

  group('FileSharePhotoStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('challory_share'));
    tearDown(() { if (dir.existsSync()) dir.deleteSync(recursive: true); });

    test('끼니 id 로 저장·조회, 없으면 null', () async {
      final store = FileSharePhotoStore.at(dir);
      await store.put('meal-1', Uint8List.fromList([1, 2, 3]));
      expect(await store.get('meal-1'), [1, 2, 3]);
      expect(await store.get('meal-2'), isNull);
    });

    test('7일이 지난 사진은 정리, 이후 조회도 null', () async {
      var now = DateTime(2026, 10, 5, 12);
      final store = FileSharePhotoStore.at(dir, clock: () => now);
      await store.put('old', Uint8List.fromList([1]));
      await store.put('new', Uint8List.fromList([2]));
      File('${dir.path}/old.jpg').setLastModifiedSync(now.subtract(const Duration(days: 8)));
      expect(await store.prune(), 1);
      expect(await store.get('old'), isNull);
      expect(await store.get('new'), [2]);
      now = now.add(const Duration(days: 8));
      expect(await store.get('new'), isNull, reason: '조회 때도 기간을 넘으면 돌려주지 않는다');
    });

    test('clear 는 모두 지운다(로그아웃·계정 삭제)', () async {
      final store = FileSharePhotoStore.at(dir);
      await store.put('a', Uint8List.fromList([1]));
      await store.clear();
      expect(await store.get('a'), isNull);
      expect(dir.existsSync() ? dir.listSync() : [], isEmpty);
    });
  });

  group('MealUploader', () {
    final photo = PreparedPhoto(
        bytes: Uint8List.fromList([9, 8, 7]), sha256: 'a' * 64, width: 1568, height: 1176, capturedAt: DateTime.utc(2026, 10, 5, 3));

    test('끼니가 만들어지면 공유용으로 사진을 보관한다', () async {
      final shares = MemorySharePhotoStore();
      final uploader = MealUploader(MockChalloryApi(), shareStore: shares);
      final meal = await uploader.submit(photo);
      expect(meal, isNotNull);
      expect(await shares.get(meal!.mealId), [9, 8, 7]);
    });

    test('업로드가 대기열로 가면 아직 보관하지 않는다', () async {
      final shares = MemorySharePhotoStore();
      final uploader = MealUploader(_OfflineApi(), shareStore: shares);
      expect(await uploader.submit(photo), isNull);
      expect(shares.photos, isEmpty);
    });
  });
}

class _OfflineApi extends MockChalloryApi {
  @override
  Future<CreatedMeal> createMeal(String photoId, {required bool queued, required String idempotencyKey}) async =>
      throw const ApiException(0, 'offline');
}
