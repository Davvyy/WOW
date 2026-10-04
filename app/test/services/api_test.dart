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

/// 서버 confirm_meal 이 보낸 항목을 meal_items 에 저장한 모양(20261004000700): 1인분·후보·국물·먹음 여부를 남긴다
Map<String, dynamic> _storedByConfirm(Map<String, dynamic> w) => {
      'chosen_name': w['chosen_name'],
      'name_candidates': w['name_candidates'] ?? const <String>[],
      'food_code': w['food_code'],
      'candidate_kcal': w['candidate_kcal'] ?? const <num>[],
      'candidate_food_codes': w['candidate_food_codes'] ?? const <String?>[],
      'serving_kcal': w['serving_kcal'],
      'count': w['count'] ?? 1,
      'portion_multiplier': w['portion_multiplier'] ?? 1,
      'broth_off': w['broth_off'] ?? false,
      'has_broth': w['has_broth'] ?? w['broth_off'] ?? false,
      'eaten': w['eaten'] ?? true,
      'needs_check': false,
      'ai_kcal': null,
      'confirmed_kcal': wireTotal([{...w, 'eaten': true}]),
    };

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
    test('밥 1.5공기 · 국물 안 먹음 ×0.6 · 개수', () {
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
    test('확정된 항목(1인분 kcal 없는 옛 행)은 확정 kcal 로 되살리고 먹음 여부를 따른다', () {
      Map<String, dynamic> row({required bool eaten}) => {
            'chosen_name': '시리얼', 'name_candidates': ['시리얼', '켈로그 첵스초코', '과자'], 'candidate_kcal': <num>[],
            'count': 1, 'portion_multiplier': 1, 'ai_kcal': null, 'serving_kcal': null, 'confirmed_kcal': 162, 'eaten': eaten,
          };
      final on = mealItemFromServer(ServerMealItem.fromJson(row(eaten: true)), 0);
      expect(on.name, '시리얼');
      expect(on.kcal, 162);
      final off = mealItemFromServer(ServerMealItem.fromJson(row(eaten: false)), 0);
      expect(off.checked, isFalse);
      expect(off.rawKcal, 162);
      expect(off.kcal, 0);
    });
    test('확정 → 서버 저장 → 다시 열기: 고른 후보·분량·국물·체크가 그대로, 다시 보내도 같은 합계', () {
      final draft = lunchDraftItems(gimChecked: false);
      final edited = [
        for (final it in draft)
          switch (it.kind) {
            ItemKind.rice => it.copyWith(mult: 1.5),
            ItemKind.soup => it.copyWith(brothOff: true, cand: it.candidates.length > 1 ? 1 : 0),
            ItemKind.count => it.copyWith(count: 3),
            ItemKind.side => it,
          },
      ];
      final wire = [for (final it in edited) mealItemToWire(it)];
      final reopened = [
        for (var i = 0; i < wire.length; i++) mealItemFromServer(ServerMealItem.fromJson(_storedByConfirm(wire[i])), i),
      ];
      for (var i = 0; i < edited.length; i++) {
        expect(reopened[i].name, edited[i].name, reason: edited[i].name);
        expect(reopened[i].checked, edited[i].checked, reason: edited[i].name);
        expect(reopened[i].rawKcal, closeTo(edited[i].rawKcal, 0.05), reason: edited[i].name);
        expect(reopened[i].candidates, edited[i].candidates, reason: edited[i].name);
      }
      expect(wireTotal([for (final it in reopened) mealItemToWire(it)]), wireTotal(wire));
      expect(reopened.where((i) => !i.checked).map((i) => i.name), [draft.last.name], reason: '김은 먹지 않음 그대로');
    });
  });

  group('먹은 양 0.1인분 단위(D60)', () {
    MealItem side(double m) => MealItem(id: 'r', candidates: const ['라면', '짜파게티'], candKcal: const [450, 600], portion: '1인분', kind: ItemKind.side, mult: m);
    MealItem rice(double m) => MealItem(id: 'b', candidates: const ['흰쌀밥', '현미밥'], candKcal: const [310, 300], portion: '1공기', kind: ItemKind.rice, mult: m);
    MealItem soup(double m) => MealItem(id: 's', candidates: const ['된장국'], candKcal: const [100], portion: '1인분', kind: ItemKind.soup, mult: m, brothOff: true);
    MealItem reopen(Map<String, dynamic> w) => mealItemFromServer(ServerMealItem.fromJson(_storedByConfirm(w)), 0);

    for (final m in [0.9, 1.2, 2.0]) {
      for (final it in [side(m), rice(m), soup(m)]) {
        test('${it.kind.name} $m인분: 서버로 보내고 다시 열어도 같은 배수·kcal', () {
          final w = mealItemToWire(it);
          expect(w['portion_multiplier'], m);
          expect(w['count'], 1);
          expect(wireTotal([w]), closeTo(it.kcal, 0.05), reason: 'wireTotal = 앱 합계');
          final back = reopen(w);
          expect(back.kind, it.kind);
          expect(back.mult, m);
          expect(back.rawKcal, closeTo(it.rawKcal, 0.05));
          expect(wireTotal([mealItemToWire(back)]), wireTotal([w]));
        });
      }
    }

    test('라면 1.2인분 = 450 × 1.2 = 540', () {
      expect(side(1.2).kcal, closeTo(540, 0.001));
      expect(wireTotal([mealItemToWire(side(1.2))]), 540);
    });

    test('배수는 소수 한 자리로 보낸다(부동소수 잔여 없음)', () {
      expect(mealItemToWire(side(0.1 + 0.2))['portion_multiplier'], 0.3);
      expect(mealItemToWire(rice(1.15000001))['portion_multiplier'], 1.2);
    });

    test('옛 반찬 행(count 3 · 배수 1)은 개수 항목으로 같은 kcal', () {
      final old = <String, dynamic>{
        'chosen_name': '멸치볶음', 'name_candidates': ['멸치볶음', '진미채볶음'], 'candidate_kcal': [20, 30],
        'serving_kcal': 20, 'count': 3, 'portion_multiplier': 1, 'eaten': true,
      };
      final back = reopen(old);
      expect(back.kind, ItemKind.count);
      expect(back.count, 3);
      expect(back.mult, 1.0);
      expect(back.rawKcal, 60);
      final w = mealItemToWire(back);
      expect([w['count'], w['portion_multiplier']], [3, 1.0]);
      expect(wireTotal([w]), 60);
    });
  });

  group('개수 항목도 1개 크기 배수를 지킨다 · 다시 연 밥·국은 개수를 배수로', () {
    MealItem reopen(Map<String, dynamic> w) => mealItemFromServer(ServerMealItem.fromJson(_storedByConfirm(w)), 0);
    Map<String, dynamic> row(String name, int serving, int count, double mult, {bool broth = false}) => {
          'chosen_name': name, 'name_candidates': [name], 'candidate_kcal': [serving], 'serving_kcal': serving,
          'count': count, 'portion_multiplier': mult, 'has_broth': broth, 'eaten': true,
        };

    test('달걀 2개 × 1.2배: kcal = 78 × 2 × 1.2, 보내고 다시 열어도 개수·배수 그대로', () {
      const egg = MealItem(id: 'e', candidates: ['삶은 달걀'], candKcal: [78], portion: '개', kind: ItemKind.count, count: 2, mult: 1.2);
      expect(egg.rawKcal, closeTo(187.2, 1e-9));
      final w = mealItemToWire(egg);
      expect([w['count'], w['portion_multiplier']], [2, 1.2]);
      expect(wireTotal([w]), 187.2);
      final back = reopen(w);
      expect(back.kind, ItemKind.count);
      expect([back.count, back.mult], [2, 1.2]);
      expect(back.rawKcal, closeTo(187.2, 1e-9));
      expect(wireTotal([mealItemToWire(back)]), 187.2);
    });

    test('개수 항목 배수도 0.1 단위로 보낸다', () {
      const egg = MealItem(id: 'e', candidates: ['삶은 달걀'], candKcal: [78], portion: '개', kind: ItemKind.count, count: 2, mult: 0.1 + 0.2);
      expect(mealItemToWire(egg)['portion_multiplier'], 0.3);
    });

    test('밥 2개 × 1.5: 밥으로 다시 열고 3.0공기, 같은 kcal', () {
      final back = reopen(row('흰쌀밥', 300, 2, 1.5));
      expect(back.kind, ItemKind.rice);
      expect([back.count, back.mult], [1, 3.0]);
      expect(back.rawKcal, 900);
      final w = mealItemToWire(back);
      expect([w['count'], w['portion_multiplier']], [1, 3.0]);
      expect(wireTotal([w]), 900);
    });

    test('국 2개 × 0.8: 국으로 다시 열고 1.6인분, 국물 토글 그대로', () {
      final back = reopen({...row('된장국', 100, 2, 0.8, broth: true), 'broth_off': true});
      expect(back.kind, ItemKind.soup);
      expect([back.count, back.mult, back.brothOff], [1, 1.6, true]);
      expect(back.rawKcal, closeTo(96, 1e-9));
    });

    test('밥 3개 × 1.5(4.5 > 3.0): 줄이면 kcal 이 바뀌므로 개수 항목으로, 같은 kcal', () {
      final back = reopen(row('흰쌀밥', 300, 3, 1.5));
      expect(back.kind, ItemKind.count);
      expect([back.count, back.mult], [3, 1.5]);
      expect(back.rawKcal, 1350);
      final w = mealItemToWire(back);
      expect([w['count'], w['portion_multiplier']], [3, 1.5]);
      expect(wireTotal([w]), 1350);
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

    test('촬영 → 서버 끼니 → 분석 초안 반영(고른 끼니로 저장, D58)', () async {
      final n = c.read(mealsProvider.notifier);
      n.reset([for (final s in MealSlot.values) MealRecord(slot: s)]);
      final err = await n.capture(MealSlot.lunch, '12:20', photo: Uint8List(3), capturedAt: DateTime.now());
      expect(err, isNull);
      final key = n.lastCapturedKey!;
      final rec = n.byKey(key)!;
      expect(rec.slot, MealSlot.lunch, reason: '서버 시각과 상관없이 고른 점심');
      expect(rec.serverId, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 1700)); // 첫 확인(1.5초)
      expect(n.byKey(key)!.status, MealStatus.draft);
      expect(n.byKey(key)!.items, isNotEmpty);
    });

    test('확정: If-Match 버전 사용 · 서버 버전 반영 · 412 면 되돌리고 안내', () async {
      final n = c.read(mealsProvider.notifier);
      final meal = await api.createMeal('p', queued: false, idempotencyKey: 'k');
      n.reset([for (final s in MealSlot.values) s == MealSlot.lunch
          ? MealRecord(slot: s, status: MealStatus.draft, serverId: meal.mealId, items: lunchDraftItems(), aiKcal: 850) : MealRecord(slot: s)]);
      final items = lunchDraftItems(gimChecked: false);
      expect(await n.confirm(MealSlot.lunch, items, 780, key: meal.mealId, aiKcal: 850), isNull);
      expect(n.byKey(meal.mealId)!.version, 2);
      expect(n.byKey(meal.mealId)!.kcal, 780);
      api.failNext = const ApiException(412, 'version mismatch');
      final err = await n.confirm(MealSlot.lunch, items, 700, key: meal.mealId);
      expect(err, contains('다른 기기'));
      expect(n.byKey(meal.mealId)!.kcal, 780, reason: '되돌림');
    });

    test('빈 슬롯 직접 입력 → meal-manual, 건너뜀 → meal-skip', () async {
      final n = c.read(mealsProvider.notifier);
      n.reset([for (final s in MealSlot.values) MealRecord(slot: s)]);
      await n.confirm(MealSlot.snack, [lunchDraftItems().last], 70, key: null);
      expect(api.calls, contains('meal-manual'));
      expect(n.inSlot(MealSlot.snack).single.serverId, isNotNull);
      await n.skip(MealSlot.breakfast);
      expect(api.calls, contains('meal-skip'));
      expect(n.inSlot(MealSlot.breakfast).single.status, MealStatus.skipped);
    });

    test('모의 시드 끼니(서버 행 없음)는 확정해도 서버를 부르지 않음', () async {
      final n = c.read(mealsProvider.notifier);
      n.reset(buildTodayMeals());
      await n.confirm(MealSlot.lunch, lunchDraftItems(gimChecked: false), 780, key: 'mock-lunch');
      expect(api.calls.where((x) => x.startsWith('meal-')), isEmpty);
    });
  });
}

/// meals 단계에서만 연결 끊김을 흉내 내고 queued 값을 기록
class _QueuedSpyApi extends MockChalloryApi {
  String? failOn;
  final queuedFlags = <bool>[];
  @override
  Future<CreatedMeal> createMeal(String photoId, {required bool queued, required String idempotencyKey, MealSlot? slot}) {
    queuedFlags.add(queued);
    if (failOn == 'meals') {
      calls.add('meals');
      throw const ApiException(0, 'offline');
    }
    return super.createMeal(photoId, queued: queued, idempotencyKey: idempotencyKey, slot: slot);
  }
}
