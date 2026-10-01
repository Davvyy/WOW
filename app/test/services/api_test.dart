import 'dart:typed_data';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/meal_wire.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/photo/meal_uploader.dart';
import 'package:challory/services/photo/photo_prep.dart';
import 'package:challory/state/app_state.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

PreparedPhoto fakePhoto() => PreparedPhoto(bytes: Uint8List.fromList([1, 2, 3]), sha256: 'a' * 64, width: 1568, height: 1176, capturedAt: DateTime.utc(2026, 10, 13, 3, 20));

void main() {
  group('사진 전처리(05 §6)', () {
    test('긴 변 1,568 px 리사이즈 · EXIF 제거 · SHA-256 은 결과 바이트 기준', () {
      final src = img.Image(width: 3000, height: 2000);
      src.exif.imageIfd['Make'] = 'TestCam';
      final jpg = Uint8List.fromList(img.encodeJpg(src));
      expect(img.decodeJpgExif(jpg)?.isEmpty ?? true, isFalse, reason: '원본에는 EXIF 가 있다');
      final out = preparePhotoSync(jpg);
      expect([out.w, out.h], [1568, 1045]);
      expect(img.decodeJpgExif(out.bytes)?.isEmpty ?? true, isTrue, reason: 'EXIF 제거');
      expect(out.sha, crypto.sha256.convert(out.bytes).toString());
    });
    test('작은 사진은 크기 유지', () {
      final out = preparePhotoSync(Uint8List.fromList(img.encodeJpg(img.Image(width: 800, height: 600))));
      expect([out.w, out.h], [800, 600]);
    });
  });

  group('P7 항목 → 서버 확정 형식', () {
    test('점심 초안(김 해제) 서버 합계 = 앱 합계 780', () {
      final items = lunchDraftItems(gimChecked: false);
      final wire = [for (final i in items) mealItemToWire(i)];
      final appTotal = items.fold(0.0, (a, i) => a + i.kcal);
      expect(wireTotal(wire), appTotal);
      expect(wireTotal(wire), 780);
      expect(wire.last['eaten'], isFalse);
    });
    test('곱빼기 ×1.5 · 국물 안 먹음 ×0.6 · 개수', () {
      final items = lunchDraftItems();
      final rice = items.firstWhere((i) => i.kind == ItemKind.rice).copyWith(mult: 1.5);
      final soup = items.firstWhere((i) => i.kind == ItemKind.soup).copyWith(brothOff: true);
      final egg = items.firstWhere((i) => i.kind == ItemKind.count).copyWith(count: 3);
      for (final it in [rice, soup, egg]) {
        expect(wireTotal([mealItemToWire(it)]), closeTo(it.kcal, 0.05), reason: it.name);
      }
      expect(mealItemToWire(soup)['broth_off'], isTrue);
    });
    test('서버 초안 항목 → P7 항목(후보 칩 kcal·국물 토글)', () {
      final s = ServerMealItem.fromJson({
        'chosen_name': '김치찌개', 'name_candidates': ['김치찌개', '부대찌개', '된장찌개'], 'candidate_kcal': [260, 480, 170],
        'candidate_food_codes': ['D000010', 'D000011', 'D000012'], 'count': 1, 'portion_multiplier': 1, 'has_broth': true,
        'needs_check': false, 'ai_kcal': 260,
      });
      final it = mealItemFromServer(s, 0);
      expect(it.kind, ItemKind.soup);
      expect(it.copyWith(cand: 1).kcal, 480);
      expect(mealItemToWire(it.copyWith(cand: 2))['food_code'], 'D000012');
    });
  });

  group('업로드 파이프라인·오프라인 큐', () {
    test('정상: 업로드 URL → PUT → 끼니 생성', () async {
      final api = MockChalloryApi();
      final m = await MealUploader(api).submit(fakePhoto());
      expect(m, isNotNull);
      expect(api.calls, ['photo-upload-url', 'upload', 'meals']);
    });
    test('연결 끊김 → 큐에 보관 → 재시도는 queued=true, 이미 끝난 단계는 건너뜀', () async {
      final api = _QueuedSpyApi();
      final up = MealUploader(api);
      api.failOn = 'meals';
      expect(await up.submit(fakePhoto(), localTag: 'lunch'), isNull);
      expect(up.pending, hasLength(1));
      api.failOn = null;
      final done = await up.retryPending();
      expect(done.single.$1, 'lunch');
      expect(up.pending, isEmpty);
      expect(api.calls.where((c) => c == 'photo-upload-url'), hasLength(1), reason: '업로드 URL 은 다시 받지 않음');
      expect(api.calls.where((c) => c == 'upload'), hasLength(1));
      expect(api.queuedFlags, [false, true]);
    });
    test('서버가 거절(422)하면 큐에 넣지 않고 오류', () async {
      final api = MockChalloryApi()..failNext = const ApiException(422, '사진이 업로드 정보와 달라요');
      final up = MealUploader(api);
      await expectLater(up.submit(fakePhoto()), throwsA(isA<ApiException>()));
      expect(up.pending, isEmpty);
    });
  });

  group('끼니 상태 ↔ 서버', () {
    late MockChalloryApi api;
    late ProviderContainer c;
    setUp(() {
      api = MockChalloryApi(analysisDelay: Duration.zero);
      c = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        mealUploaderProvider.overrideWithValue(MealUploader(api, prepare: (b, t) async => fakePhoto())),
      ]);
    });
    tearDown(() => c.dispose());

    test('촬영 → 서버 끼니 → 분석 초안 반영(슬롯은 서버가 정함)', () async {
      final n = c.read(mealsProvider.notifier);
      n.reset([for (final s in MealSlot.values) MealRecord(slot: s)]);
      final err = await n.capture(MealSlot.lunch, '12:20', photo: Uint8List(3), capturedAt: DateTime.now());
      expect(err, isNull);
      final serverSlot = slotForKst(DateTime.now());
      final rec = n.of(serverSlot);
      expect(rec.serverId, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 1700)); // 첫 확인(1.5초)
      expect(n.of(serverSlot).status, MealStatus.draft);
      expect(n.of(serverSlot).items, isNotEmpty);
    });

    test('확정: If-Match 버전 사용 · 서버 버전 반영 · 412 면 되돌리고 안내', () async {
      final n = c.read(mealsProvider.notifier);
      final meal = await api.createMeal('p', queued: false, idempotencyKey: 'k');
      n.reset([for (final s in MealSlot.values) s == MealSlot.lunch
          ? MealRecord(slot: s, status: MealStatus.draft, serverId: meal.mealId, items: lunchDraftItems(), aiKcal: 850) : MealRecord(slot: s)]);
      final items = lunchDraftItems(gimChecked: false);
      expect(await n.confirm(MealSlot.lunch, items, 780, aiKcal: 850), isNull);
      expect(n.of(MealSlot.lunch).version, 2);
      expect(n.of(MealSlot.lunch).kcal, 780);
      api.failNext = const ApiException(412, 'version mismatch');
      final err = await n.confirm(MealSlot.lunch, items, 700);
      expect(err, contains('다른 기기'));
      expect(n.of(MealSlot.lunch).kcal, 780, reason: '되돌림');
    });

    test('빈 슬롯 직접 입력 → meal-manual, 건너뜀 → meal-skip', () async {
      final n = c.read(mealsProvider.notifier);
      n.reset([for (final s in MealSlot.values) MealRecord(slot: s)]);
      await n.confirm(MealSlot.snack, [lunchDraftItems().last], 70);
      expect(api.calls, contains('meal-manual'));
      expect(n.of(MealSlot.snack).serverId, isNotNull);
      await n.skip(MealSlot.breakfast);
      expect(api.calls, contains('meal-skip'));
      expect(n.of(MealSlot.breakfast).status, MealStatus.skipped);
    });

    test('모의 시드 끼니(서버 행 없음)는 확정해도 서버를 부르지 않음', () async {
      final n = c.read(mealsProvider.notifier);
      n.reset(buildTodayMeals());
      await n.confirm(MealSlot.lunch, lunchDraftItems(gimChecked: false), 780);
      expect(api.calls.where((x) => x.startsWith('meal-')), isEmpty);
    });
  });
}

/// meals 단계에서만 연결 끊김을 흉내 내고 queued 값을 기록
class _QueuedSpyApi extends MockChalloryApi {
  String? failOn;
  final queuedFlags = <bool>[];
  @override
  Future<CreatedMeal> createMeal(String photoId, {required bool queued, required String idempotencyKey}) {
    queuedFlags.add(queued);
    if (failOn == 'meals') {
      calls.add('meals');
      throw const ApiException(0, 'offline');
    }
    return super.createMeal(photoId, queued: queued, idempotencyKey: idempotencyKey);
  }
}
