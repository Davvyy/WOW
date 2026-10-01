import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/services/api/server_mapping.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notifications 행 → 공지(KST 날짜·읽음)', () {
    final n = noticeFromServer({'id': 'a', 'title': '최종 결과는 11.3 09:00에 확정돼요', 'body': '본문', 'scheduled_at': '2026-10-12T09:00:00+00:00', 'read_at': null});
    expect([n.title, n.read, n.at.month, n.at.day, n.at.hour], ['최종 결과는 11.3 09:00에 확정돼요', false, 10, 12, 18]);
    expect(noticeFromServer({'id': 'b', 'title': null, 'body': null, 'scheduled_at': '2026-10-06T00:00:00Z', 'read_at': '2026-10-06T01:00:00Z'}).read, isTrue);
  });

  test('목록 읽기 · 모두 읽음은 안 읽은 것만 서버에 보냄', () async {
    final api = MockChalloryApi();
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final list = await c.read(noticesProvider.future);
    expect(list, hasLength(3));
    expect(c.read(noticesProvider.notifier).unread, 1);
    await c.read(noticesProvider.notifier).markAllRead();
    expect(c.read(noticesProvider.notifier).unread, 0);
    expect(api.notices.every((n) => n.read), isTrue);
    expect(api.calls.where((x) => x == 'notices-read'), hasLength(1));
    await c.read(noticesProvider.notifier).markAllRead();
    expect(api.calls.where((x) => x == 'notices-read'), hasLength(1), reason: '이미 읽은 공지는 다시 보내지 않음');
  });

  Future<MockChalloryApi> pump(WidgetTester tester, String location) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = MockChalloryApi();
    final router = buildRouter(initialLocation: location);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiProvider.overrideWithValue(api)],
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('P12 공지: 안 읽음 1 → 열면 목록 3건 · 모두 읽음 · 눌러서 본문', (tester) async {
    final api = await pump(tester, R.settings);
    expect(find.textContaining('읽지 않음 1'), findsOneWidget);
    await tester.tap(find.text('공지'));
    await tester.pumpAndSettle();
    expect(find.text('점검 기간이 끝났어요 · 10.9부터 누적 반영'), findsOneWidget);
    expect(find.textContaining('새 공지'), findsOneWidget);
    expect(api.notices.first.read, isTrue);
    await tester.tap(find.text('가을 걷기 챌린지가 시작됐어요'));
    await tester.pumpAndSettle();
    expect(find.text('오늘부터 28일 동안 진행돼요. 첫 3일은 점검 기간이에요.'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('모두 읽음'), findsOneWidget);
  });

  testWidgets('P5 공지 배너: 최신 공지 · 누르면 읽음', (tester) async {
    final api = await pump(tester, R.home);
    expect(find.textContaining('최종 결과는 11.3 09:00에 확정돼요'), findsWidgets);
    expect(api.notices.first.read, isFalse);
    await tester.tap(find.textContaining('[공지]'));
    await tester.pumpAndSettle();
    expect(api.notices.first.read, isTrue);
  });
}
