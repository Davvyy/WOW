// 한 슬롯에 끼니가 여러 개: 모두 목록에 남고, 끼니 하나만 바꾸고 지운다.
import 'dart:async';
import 'dart:typed_data';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/photo/meal_uploader.dart';
import 'package:challory/services/share/meal_share.dart';
import 'package:challory/state/app_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

PreparedPhoto _photo() => PreparedPhoto(bytes: Uint8List.fromList([1, 2, 3]), sha256: 'a' * 64, width: 1568, height: 1176, capturedAt: DateTime.utc(2026, 10, 13, 3, 20));

/// 서버 모드: 오늘 끼니 응답을 정해 둔다
class _RemoteMeals extends MockChalloryApi {
  _RemoteMeals(this.rows) : super(analysisDelay: const Duration(hours: 1));
  final List<ServerMeal> rows;
  @override
  bool get isRemote => true;
  @override
  Future<List<ServerMeal>> fetchMealsOn(String localDate) async => rows;
}

ServerMeal _row(String id, int hour, double kcal) => ServerMeal(
      id: id,
      status: MealStatus.confirmed,
      version: 2,
      confirmedKcal: kcal,
      slot: MealSlot.breakfast,
      capturedAt: DateTime.utc(2026, 10, 12, hour - 9), // KST hour
    );

List<MealRecord> _breakfasts(ProviderContainer c) => [for (final m in c.read(mealsProvider)) if (m.slot == MealSlot.breakfast && m.status != MealStatus.empty) m];

void main() {
  _fixRound1();
  test('loadToday: 아침 3건을 모두 촬영 시각 순으로 남긴다', () async {
    final api = _RemoteMeals([_row('b-2', 8, 300), _row('b-1', 7, 200), _row('b-3', 9, 400)]);
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    expect(await c.read(mealsProvider.notifier).loadToday(), isNull);
    final b = _breakfasts(c);
    expect([for (final m in b) m.serverId], ['b-1', 'b-2', 'b-3']);
    expect([for (final m in b) m.kcal], [200, 300, 400]);
    expect([for (final m in b) m.time], ['07:00', '08:00', '09:00']);
    // 엔진 입력에도 셋 다 들어간다
    expect(c.read(todayResultProvider).intake.iD, greaterThanOrEqualTo(900));
  });

  test('확정된 점심이 있는 슬롯에 찍으면 끼니가 하나 더 생기고 처음 끼니는 그대로', () async {
    // 12:20 KST → 서버 슬롯 점심, 분석은 오래 걸리는 것으로(초안으로 바뀌지 않게)
    final api = MockChalloryApi(analysisDelay: const Duration(hours: 1), clock: () => DateTime.utc(2026, 10, 13, 3, 20));
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      mealUploaderProvider.overrideWithValue(MealUploader(api, prepare: (b, t) async => _photo())),
      mealsProvider.overrideWith(() => MealsNotifier(buildTodayMeals())),
    ]);
    addTearDown(c.dispose);
    final n = c.read(mealsProvider.notifier);
    final err = await n.capture(MealSlot.lunch, '12:40', photo: Uint8List(3), capturedAt: DateTime.now());
    expect(err, isNull);
    final lunch = [for (final m in c.read(mealsProvider)) if (m.slot == MealSlot.lunch) m];
    expect(lunch, hasLength(2));
    expect(lunch.first.status, MealStatus.confirmed);
    expect(lunch.first.kcal, 780);
    expect(lunch.first.title, '김치찌개 백반');
    expect(lunch.last.status, MealStatus.captured);
    expect(lunch.last.serverId, isNotNull);
    expect(lunch.last.time, '12:40');
  });

  group('끼니 하나만 바꾸고 지운다', () {
    late MockChalloryApi api;
    late ProviderContainer c;
    late MealsNotifier n;
    // 아침에 서버 끼니 둘: 확정 420 + AI 초안
    final first = const MealRecord(slot: MealSlot.breakfast, status: MealStatus.confirmed, kcal: 420, title: '계란토스트', time: '07:40', serverId: 'm-1', version: 2);
    final second = MealRecord(slot: MealSlot.breakfast, status: MealStatus.draft, aiKcal: 300, title: '요거트', time: '10:10', serverId: 'm-2', items: mockDraftItems(MealSlot.breakfast));

    setUp(() {
      api = MockChalloryApi(analysisDelay: Duration.zero);
      c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api), mealsProvider.overrideWith(() => MealsNotifier([first, second]))]);
      n = c.read(mealsProvider.notifier);
    });
    tearDown(() => c.dispose());

    test('두 번째 끼니를 확정해도 첫 끼니는 그대로', () async {
      final items = mockDraftItems(MealSlot.breakfast);
      final total = items.fold(0.0, (a, i) => a + i.kcal);
      expect(await n.confirm(MealSlot.breakfast, items, total, key: 'm-2'), isNull);
      final b = n.inSlot(MealSlot.breakfast);
      expect(b, hasLength(2));
      expect(b.first.serverId, 'm-1');
      expect(b.first.status, MealStatus.confirmed);
      expect(b.first.kcal, 420);
      expect(b.first.title, '계란토스트');
      expect(b.last.serverId, 'm-2');
      expect(b.last.status, MealStatus.confirmed);
      expect(b.last.kcal, total);
      // 섭취 = 두 끼니 합
      expect(c.read(todayResultProvider).intake.iD, greaterThanOrEqualTo(420 + total));
    });

    test('지우기: 그 끼니만 빠지고 서버 meal-delete 를 부른다', () async {
      expect(await n.delete('m-2'), isNull);
      expect(api.deletedMeals, ['m-2']);
      expect([for (final m in n.inSlot(MealSlot.breakfast)) m.serverId], ['m-1']);
    });

    test('지우기 실패(확정된 날짜): 제자리에 되돌리고 서버 문구', () async {
      api.failNext = const ApiException(422, '확정된 날짜의 기록은 지울 수 없어요');
      final pending = n.delete('m-1');
      expect([for (final m in c.read(mealsProvider)) m.serverId], ['m-2'], reason: '화면에서 먼저 뺀다');
      expect(await pending, '확정된 날짜의 기록은 지울 수 없어요');
      expect([for (final m in c.read(mealsProvider)) m.serverId], ['m-1', 'm-2'], reason: '같은 자리에 되돌림');
    });

    test('건너뜀은 기록이 없는 슬롯에만 더한다', () async {
      expect(await n.skip(MealSlot.breakfast), isNotNull);
      expect(n.inSlot(MealSlot.breakfast), hasLength(2));
      expect(await n.skip(MealSlot.dinner), isNull);
      expect(n.inSlot(MealSlot.dinner).single.status, MealStatus.skipped);
      expect(await n.skip(MealSlot.snack), isNotNull, reason: '간식은 건너뛸 수 없다');
      expect(n.inSlot(MealSlot.snack), isEmpty);
    });

    test('분석 갱신은 그 끼니에만(같은 슬롯의 다른 끼니는 그대로)', () async {
      final made = await api.createMeal('p', queued: false, idempotencyKey: 'k');
      n.reset([first, MealRecord(slot: MealSlot.breakfast, status: MealStatus.captured, serverId: made.mealId)]);
      expect(await n.refreshMeal(made.mealId), isTrue);
      final b = n.inSlot(MealSlot.breakfast);
      expect(b.first.status, MealStatus.confirmed);
      expect(b.first.kcal, 420);
      expect(b.last.status, MealStatus.draft);
    });
  });
}

/// 서버 모드에서 지우기 응답을 정해 둔다. [gate] 를 채우면 응답 전에 기다린다.
class _DeleteApi extends MockChalloryApi {
  _DeleteApi(this.error);
  final ApiException? error;
  Future<void>? gate;
  @override
  bool get isRemote => true;
  @override
  Future<List<ServerMeal>> fetchMealsOn(String localDate) async => const [];
  @override
  Future<void> deleteMeal(String mealId, {required String idempotencyKey}) async {
    calls.add('meal-delete');
    if (gate != null) await gate;
    if (error != null) throw error!;
  }
}

void _fixRound1() {
  group('지우기 응답 처리', () {
    const meal = MealRecord(slot: MealSlot.lunch, status: MealStatus.confirmed, kcal: 600, title: '비빔밥', serverId: 'm-9', version: 2);

    ProviderContainer make(_DeleteApi api, MemorySharePhotoStore shares) {
      final c = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        sharePhotoStoreProvider.overrideWithValue(shares),
        mealsProvider.overrideWith(() => MealsNotifier([meal])),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('404(이미 지워짐)는 지운 것으로: 행은 빠진 채, 장부 다시 읽기, 보관 사진 삭제, 성공(null)', () async {
      final api = _DeleteApi(const ApiException(404, '기록을 찾지 못했어요'));
      final shares = MemorySharePhotoStore()..photos['m-9'] = Uint8List.fromList([1]);
      final c = make(api, shares);
      final sub = c.listen(ledgerProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpEventQueue();
      final ledgerReads = api.calls.where((x) => x == 'ledger').length;
      expect(await c.read(mealsProvider.notifier).delete('m-9'), isNull);
      await pumpEventQueue();
      expect(c.read(mealsProvider), isEmpty);
      expect(shares.photos.containsKey('m-9'), isFalse);
      expect(api.calls.where((x) => x == 'ledger').length, ledgerReads + 1, reason: '장부를 다시 읽는다');
    });

    test('연결 끊김(0)은 지우기 전용 문구 · 행은 되돌림', () async {
      final api = _DeleteApi(const ApiException(0, 'offline'));
      final c = make(api, MemorySharePhotoStore());
      expect(await c.read(mealsProvider.notifier).delete('m-9'), '연결이 불안정해요. 잠시 뒤 다시 지워 주세요');
      expect([for (final m in c.read(mealsProvider)) m.serverId], ['m-9']);
    });

    test('지우는 중에 새로고침으로 같은 끼니가 다시 들어왔으면 실패해도 두 번 넣지 않는다', () async {
      final gate = Completer<void>();
      final api = _DeleteApi(const ApiException(422, '판정된 기록은 지울 수 없어요'))..gate = gate.future;
      final c = make(api, MemorySharePhotoStore());
      final n = c.read(mealsProvider.notifier);
      final pending = n.delete('m-9');
      expect(c.read(mealsProvider), isEmpty);
      n.reset([meal]); // 새로고침이 그 끼니를 다시 가져옴
      gate.complete();
      expect(await pending, '판정된 기록은 지울 수 없어요');
      expect([for (final m in c.read(mealsProvider)) m.serverId], ['m-9']);
    });
  });
}
