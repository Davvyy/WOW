// 지난 끼니 사진(전수 점검 #22): 이 폰에 보관본이 없어도(다시 설치·7일 지남·다른 폰) 사진이 있는 서버 끼니는
// 서버 사본(Edge photo-url 서명 URL)을 받아 P7 사진 칸과 홈 썸네일에 보인다. 끼니마다 세션 동안 메모리에 한 번만 받는다.
// 사진 없는 기록·보관본이 있는 끼니·모의 모드는 서버에 묻지 않는다.
import 'dart:typed_data';

import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/services/share/meal_share.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/day_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;

import 'screens_test.dart' show pumpApp;

Uint8List _png() => Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6)));

/// 서버 사진을 주는 가짜 API. [remote] 가 false 면 모의 모드.
/// 서버 모드 홈은 오늘 끼니를 서버에서 다시 읽으므로 점심 한 끼(사진 여부 [photoless])를 준다.
class _PhotoApi extends MockChalloryApi {
  _PhotoApi({this.remote = true, this.photoless = false, Map<String, Uint8List>? photos}) : photos = photos ?? {};
  final bool remote;
  final bool photoless;
  final Map<String, Uint8List> photos;
  final asked = <String>[];

  @override
  bool get isRemote => remote;

  bool deleted = false;

  @override
  Future<void> deleteMeal(String mealId, {required String idempotencyKey}) async => deleted = true;

  @override
  Future<List<ServerMeal>> fetchMealsOn(String localDate) async => deleted ? const [] : [
    ServerMeal(
      id: _lunchId,
      status: MealStatus.confirmed,
      version: 2,
      confirmedKcal: 520,
      slot: MealSlot.lunch,
      capturedAt: DateTime.now().toUtc(),
      hasPhoto: !photoless,
      items: const [
        ServerMealItem(
          candidates: ['비빔밥'],
          candidateKcal: [520],
          candidateFoodCodes: [null],
          count: 1,
          portionMultiplier: 1,
          hasBroth: false,
          needsCheck: false,
          aiKcal: 520,
        ),
      ],
    ),
  ];

  @override
  Future<Uint8List?> fetchMealPhoto(String mealId) async {
    asked.add(mealId);
    return photos[mealId];
  }
}

const _lunchId = 'm-lunch-1';

List<MealRecord> _meals({bool photoless = false}) => [
  for (final m in buildTodayMeals())
    if (m.slot == MealSlot.lunch) m.copyWith(serverId: _lunchId, localKey: _lunchId, photoless: photoless) else m,
];

/// P7 사진 칸의 DecorationImage 가 MemoryImage 면 그 바이트
Uint8List? _p7Photo(WidgetTester tester) {
  for (final c in tester.widgetList<Container>(find.byType(Container))) {
    final d = c.decoration;
    if (d is BoxDecoration && d.image?.image is MemoryImage) return (d.image!.image as MemoryImage).bytes;
  }
  return null;
}

Iterable<Image> _thumbs(WidgetTester tester) =>
    tester.widgetList<Image>(find.descendant(of: find.byType(DayTimelineRow), matching: find.byType(Image)));

Future<ProviderContainer> _open(WidgetTester tester, _PhotoApi api, {String? location, bool photoless = false, SharePhotoStore? shares}) {
  addTearDown(resetSession);
  return pumpApp(
    tester,
    location: location ?? R.meal(MealSlot.lunch, meal: _lunchId),
    overrides: [
      apiProvider.overrideWithValue(api),
      authServiceProvider.overrideWithValue(MockAuthService(true)),
      mealsProvider.overrideWith(() => MealsNotifier(_meals(photoless: photoless))),
      sharePhotoStoreProvider.overrideWithValue(shares ?? MemorySharePhotoStore()),
    ],
  );
}

void main() {
  testWidgets('P7: 보관본이 없으면 서버 사본을 받아 사진 칸에 보인다', (tester) async {
    final png = _png();
    final api = _PhotoApi(photos: {_lunchId: png});
    await _open(tester, api);
    expect(api.asked, [_lunchId]);
    expect(_p7Photo(tester), png);
  });

  testWidgets('P7: 이 폰에 보관본이 있으면 서버에 묻지 않는다', (tester) async {
    final local = _png();
    final api = _PhotoApi(photos: {_lunchId: _png()});
    await _open(tester, api, shares: MemorySharePhotoStore()..photos[_lunchId] = local);
    expect(api.asked, isEmpty);
    expect(_p7Photo(tester), local);
  });

  testWidgets('P7: 사진 없이 기록한 끼니(hasPhoto false)는 서버에 묻지 않고 사진 칸도 없다', (tester) async {
    final api = _PhotoApi(photos: {_lunchId: _png()});
    await _open(tester, api, photoless: true);
    expect(api.asked, isEmpty);
    expect(_p7Photo(tester), isNull);
    expect(find.text('인앱 촬영 · 서버 시각'), findsNothing);
  });

  testWidgets('P7: 서버에도 없으면(404·파기) 지금처럼 색 배경', (tester) async {
    final api = _PhotoApi();
    await _open(tester, api);
    expect(api.asked, [_lunchId]);
    expect(_p7Photo(tester), isNull);
    expect(find.text('인앱 촬영 · 서버 시각'), findsOneWidget);
  });

  testWidgets('모의 모드: 서버 사진을 묻지 않는다(지금 동작 그대로)', (tester) async {
    final api = _PhotoApi(remote: false, photos: {_lunchId: _png()});
    await _open(tester, api);
    expect(api.asked, isEmpty);
    expect(_p7Photo(tester), isNull);
  });

  testWidgets('홈 썸네일: 보관본이 없으면 서버 사본, 다시 열어도 세션 동안 한 번만 받는다', (tester) async {
    final png = _png();
    final api = _PhotoApi(photos: {_lunchId: png});
    await _open(tester, api, location: R.home);
    await tester.pumpAndSettle();
    final thumbs = _thumbs(tester).toList();
    expect(thumbs, hasLength(1));
    expect(((thumbs.single.image as ResizeImage).imageProvider as MemoryImage).bytes, png);
    expect(api.asked, [_lunchId]);
    // 홈 → P7 → 홈: 메모리 캐시에서 꺼낸다
    GoRouter.of(tester.element(find.byType(DayTimelineRow).first)).push(R.meal(MealSlot.lunch, meal: _lunchId));
    await tester.pumpAndSettle();
    expect(_p7Photo(tester), png);
    GoRouter.of(tester.element(find.byType(Scaffold).last)).pop();
    await tester.pumpAndSettle();
    expect(_thumbs(tester), hasLength(1));
    expect(api.asked, [_lunchId], reason: '끼니마다 한 번');
  });

  testWidgets('홈 썸네일: 사진 없는 기록은 묻지 않는다', (tester) async {
    final api = _PhotoApi(photoless: true, photos: {_lunchId: _png()});
    await _open(tester, api, location: R.home, photoless: true);
    await tester.pumpAndSettle();
    expect(_thumbs(tester), isEmpty);
    expect(api.asked, isEmpty);
  });

  testWidgets('끼니를 지우면 메모리 사본도 잊는다', (tester) async {
    final api = _PhotoApi(photos: {_lunchId: _png()});
    final c = await _open(tester, api, location: R.home);
    await tester.pumpAndSettle();
    expect(api.asked, [_lunchId]);
    final cache = c.read(serverPhotoCacheProvider);
    expect(cache.has(_lunchId), isTrue);
    expect(await c.read(mealsProvider.notifier).delete(_lunchId), isNull);
    await tester.pumpAndSettle();
    expect(cache.has(_lunchId), isFalse);
    expect(api.asked, [_lunchId], reason: '지운 끼니를 다시 받지 않는다');
  });
}
