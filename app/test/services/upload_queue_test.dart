// 업로드 대기열 디스크 저장: 오프라인 → 앱 종료 → 재실행 → 이어서 보내기
import 'dart:io';
import 'dart:typed_data';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/models.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/photo/meal_uploader.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/meal_slot_card.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

PreparedPhoto photo([int seed = 1]) => PreparedPhoto(
    bytes: Uint8List.fromList(List.generate(64, (i) => (i * seed) % 256)), sha256: 'a' * 64, width: 1568, height: 1176,
    capturedAt: DateTime.utc(2026, 10, 13, 3, 20));

/// 단계별로 오류를 흉내 내는 서버
class _FlakyApi extends MockChalloryApi {
  _FlakyApi({super.clock});
  final failOn = <String, ApiException>{}; // 'upload' | 'meals' → 한 번 던질 오류
  final queuedFlags = <bool>[];
  final snackFlags = <bool>[];
  final uploadKeys = <String>[];
  int uploads = 0;

  ApiException? _take(String k) => failOn.remove(k);

  @override
  Future<PhotoUploadTicket> requestPhotoUpload(PreparedPhoto p, {required String idempotencyKey}) {
    uploadKeys.add(idempotencyKey);
    return super.requestPhotoUpload(p, idempotencyKey: idempotencyKey);
  }

  @override
  Future<void> uploadPhoto(PhotoUploadTicket t, Uint8List bytes) async {
    final e = _take('upload');
    if (e != null) throw e;
    uploads++;
  }

  @override
  Future<CreatedMeal> createMeal(String photoId, {required bool queued, required String idempotencyKey, bool snack = false}) {
    queuedFlags.add(queued);
    snackFlags.add(snack);
    final e = _take('meals');
    if (e != null) throw e;
    return super.createMeal(photoId, queued: queued, idempotencyKey: idempotencyKey, snack: snack);
  }
}

Uint8List _jpeg() => Uint8List.fromList(img.encodeJpg(img.Image(width: 200, height: 150)));

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('challory_queue'));
  tearDown(() => dir.deleteSync(recursive: true));
  List<String> files() => dir.existsSync() ? (dir.listSync().map((f) => f.uri.pathSegments.last).toList()..sort()) : [];

  test('오프라인 → 사진·상태 저장 → 재실행 후 이어서 보내기(업로드는 다시 안 함, queued=true) → 파일 삭제', () async {
    final api = _FlakyApi()..failOn['meals'] = const ApiException(0, 'offline');
    final first = MealUploader(api, store: FilePendingStore.at(dir));
    expect(await first.submit(photo(), localTag: 'lunch'), isNull);
    expect(files(), hasLength(2), reason: 'jpg + json');
    expect(api.uploads, 1);

    // 앱 재시작: 새 업로더가 같은 폴더를 읽는다
    final second = MealUploader(api, store: FilePendingStore.at(dir));
    final restored = await second.restore();
    expect(restored, hasLength(1));
    expect(restored.single.localTag, 'lunch');
    expect(restored.single.uploaded, isTrue);
    expect(restored.single.ticket, isNotNull);
    expect(restored.single.photo.bytes, photo().bytes);

    final done = await second.retryPending();
    expect(done.single.$1, 'lunch');
    expect(api.uploads, 1, reason: '이미 올린 사진은 다시 올리지 않음');
    expect(api.queuedFlags, [false, true]);
    expect(files(), isEmpty);
  });

  test('업로드 URL 만료(앱을 오래 꺼 둠) → 새 키로 URL 다시 받아 업로드', () async {
    final api = _FlakyApi()..failOn['upload'] = const ApiException(0, 'offline');
    final up = MealUploader(api, store: FilePendingStore.at(dir));
    await up.submit(photo(), localTag: 'dinner');
    final again = MealUploader(api, store: FilePendingStore.at(dir));
    api.failOn['upload'] = const ApiException(400, 'token expired');
    final done = await again.retryPending();
    expect(done, hasLength(1));
    expect(api.uploadKeys, hasLength(2));
    expect(api.uploadKeys.toSet(), hasLength(2), reason: '새 업로드 키');
    expect(files(), isEmpty);
  });

  test('서버가 거절(422)하면 대기열·파일에서 지움', () async {
    final api = _FlakyApi()..failOn['meals'] = const ApiException(0, 'offline');
    final up = MealUploader(api, store: FilePendingStore.at(dir));
    await up.submit(photo());
    api.failOn['meals'] = const ApiException(422, '챌린지 기간 밖의 사진이에요');
    await expectLater(up.retryPending(), throwsA(isA<ApiException>()));
    expect(up.pending, isEmpty);
    expect(files(), isEmpty);
  });

  test('7일 지난 대기는 버림 · 망가진 파일은 건너뛰고 지움', () async {
    final api = _FlakyApi()..failOn['meals'] = const ApiException(0, 'offline');
    final now = DateTime.utc(2026, 10, 13);
    await MealUploader(api, store: FilePendingStore.at(dir), clock: () => now).submit(photo());
    File('${dir.path}/broken.json').writeAsStringSync('{not json');
    final later = MealUploader(api, store: FilePendingStore.at(dir), clock: () => now.add(const Duration(days: 8)));
    expect(await later.restore(), isEmpty);
    expect(files(), isEmpty);
  });

  test('재시도 5회 넘으면 자동 재시도는 멈추고, 새로고침(force)만 보냄', () async {
    final api = _FlakyApi();
    final up = MealUploader(api, store: FilePendingStore.at(dir));
    api.failOn['meals'] = const ApiException(503, 'down');
    await up.submit(photo());
    for (var i = 0; i < 6; i++) {
      api.failOn['meals'] = const ApiException(503, 'down');
      await up.retryPending();
    }
    expect(up.pending.single.attempts, MealUploader.maxAttempts);
    api.failOn.clear();
    expect(await up.retryPending(), isEmpty, reason: '상한 도달');
    expect(await up.retryPending(force: true), hasLength(1));
  });

  test('간식으로 찍은 사진은 대기열에서 다시 보낼 때도 간식으로(D55)', () async {
    final api = _FlakyApi()..failOn['meals'] = const ApiException(0, 'offline');
    expect(await MealUploader(api, store: FilePendingStore.at(dir)).submit(photo(), localTag: 'snack'), isNull);
    final done = await MealUploader(api, store: FilePendingStore.at(dir)).retryPending();
    expect(done.single.$1, 'snack');
    expect(api.snackFlags, [true, true]);
    await MealUploader(api, store: FilePendingStore.at(dir)).submit(photo(2), localTag: 'lunch');
    expect(api.snackFlags.last, isFalse, reason: '끼니 칸은 서버 시각 그대로');
  });

  testWidgets('07:00 에 간식을 골라 찍으면 간식 칸에, 아침을 고르면 아침 칸에(D55)', (tester) async {
    final api = _FlakyApi(clock: () => DateTime.utc(2026, 10, 12, 22)); // KST 07:00
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final n = c.read(mealsProvider.notifier);
    n.reset([for (final s in MealSlot.values) MealRecord(slot: s)]);

    await tester.runAsync(() => n.capture(MealSlot.snack, '07:00', photo: _jpeg(), capturedAt: DateTime.now()));
    expect(api.snackFlags, [true]);
    expect(n.lastCapturedSlot, MealSlot.snack);
    expect(n.inSlot(MealSlot.snack).single.serverId, isNotNull);
    expect(n.inSlot(MealSlot.snack).single.status, MealStatus.captured);
    expect(n.inSlot(MealSlot.breakfast), isEmpty, reason: '아침 칸은 그대로 빈 칸');

    await tester.runAsync(() => n.capture(MealSlot.breakfast, '07:00', photo: _jpeg(), capturedAt: DateTime.now()));
    expect(api.snackFlags, [true, false]);
    expect(n.lastCapturedSlot, MealSlot.breakfast);
    expect(n.inSlot(MealSlot.breakfast).single.serverId, isNotNull);
  });

  testWidgets('재실행 후 홈 끼니 칸에 "업로드 대기" 표시', (tester) async {
    final api = _FlakyApi()..failOn['meals'] = const ApiException(0, 'offline');
    await tester.runAsync(() => MealUploader(api, store: FilePendingStore.at(dir)).submit(photo(), localTag: 'lunch'));
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      mealUploaderProvider.overrideWithValue(MealUploader(api, store: FilePendingStore.at(dir))),
    ]);
    addTearDown(c.dispose);
    final n = c.read(mealsProvider.notifier);
    n.reset([for (final s in MealSlot.values) MealRecord(slot: s)]);
    expect(await tester.runAsync(() => n.restorePendingUploads()), 1);
    final lunch = n.inSlot(MealSlot.lunch).single;
    expect(lunch.pendingUpload, isTrue);
    expect(lunch.time, '12:20');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: MealSlotCard(meal: lunch))),
    ));
    expect(find.text('업로드 대기'), findsOneWidget);
  });
}
