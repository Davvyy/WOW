// P7 끼니 항목이 비었을 때: 예시(프로토타입) 음식으로 채우지 않고 '음식을 찾지 못했어요' 검색·직접 입력 화면을 띄운다.
// 업로드 대기·분석 불가·AI 끔·'지금 확정'(analyze=false) 모두 같은 화면. 확정 버튼은 음식을 고르기 전까지 꺼져 있다.
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/auth/auth_service.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Remote extends MockChalloryApi {
  @override
  bool get isRemote => true;
}

List<MealRecord> _withLunch(MealRecord lunch) => [
      for (final m in buildTodayMeals()) if (m.slot != MealSlot.lunch) m,
      lunch,
    ];

Future<void> _open(WidgetTester tester, MealRecord lunch, {required bool remote}) async {
  tester.view.physicalSize = const Size(420, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(resetSession);
  final router = buildRouter(initialLocation: R.meal(MealSlot.lunch, meal: lunch.key));
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      if (remote) apiProvider.overrideWithValue(_Remote()),
      authServiceProvider.overrideWithValue(MockAuthService(true)),
      mealsProvider.overrideWith(() => MealsNotifier(_withLunch(lunch))),
    ],
    child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

Finder _confirmButton() => find.byWidgetPredicate((w) => w is ChButton && w.label.startsWith('확정'));

void _expectSearchFallback(WidgetTester tester) {
  expect(find.textContaining('음식을 찾지 못했어요'), findsOneWidget);
  expect(find.text('직접 입력 (이름·kcal)'), findsOneWidget);
  for (final name in ['흰쌀밥', '김치찌개', '계란말이']) {
    expect(find.text(name), findsNothing, reason: '예시 음식($name)으로 채우지 않는다');
  }
  expect(find.textContaining('850'), findsNothing, reason: '예시 초안 합계(850 kcal)를 쓰지 않는다');
  final btn = find.byWidgetPredicate((w) => w is ChButton && w.label == '확정');
  expect(btn, findsOneWidget);
  expect(tester.widget<ChButton>(btn).onPressed, isNull, reason: '음식을 고르기 전에는 확정할 수 없다');
}

void main() {
  const pending = MealRecord(slot: MealSlot.lunch, status: MealStatus.captured, pendingUpload: true, time: '12:20', localKey: 'local-pending');
  const failed = MealRecord(slot: MealSlot.lunch, status: MealStatus.failed, noAnalysis: true, time: '12:20', serverId: 'm-failed', localKey: 'm-failed');
  const noAi = MealRecord(slot: MealSlot.lunch, status: MealStatus.captured, noAnalysis: true, time: '12:20', serverId: 'm-noai', localKey: 'm-noai');

  for (final remote in [true, false]) {
    final mode = remote ? '서버 모드' : '모의 모드';
    testWidgets('$mode: 업로드 대기 끼니 → 검색 화면, 예시 음식 없음', (t) async {
      await _open(t, pending, remote: remote);
      _expectSearchFallback(t);
    });

    testWidgets('$mode: 분석 불가 끼니(검색 표시 없이 연 알림) → 검색 화면', (t) async {
      await _open(t, failed, remote: remote);
      _expectSearchFallback(t);
    });

    testWidgets('$mode: AI 끔 끼니 → 검색 화면', (t) async {
      await _open(t, noAi, remote: remote);
      _expectSearchFallback(t);
      expect(_confirmButton(), findsOneWidget);
    });
  }
}
