// 늦게 참가한 사람: 홈 날짜는 참가(점검 시작) 첫날부터만 고를 수 있다
import 'package:challory/data/models.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 시작일 + 3일째(4일째)에 참가한 세션. 오늘도 4일째.
ChallengeSession _lateJoiner() {
  final base = ChallengeSession.mock;
  final c = base.challenge;
  final joinDay = c.start.add(const Duration(days: 3));
  return ChallengeSession(
    challenge: ChallengeInfo(
      name: c.name, code: c.code, start: c.start, end: c.end, days: c.days, capacity: c.capacity, joined: c.joined,
      today: joinDay, dayIndex: 4, syncTime: c.syncTime, source: c.source, platform: c.platform,
      noticeTitle: c.noticeTitle, noticeBody: c.noticeBody, noticeDate: c.noticeDate, objectionUntil: c.objectionUntil),
    me: base.me,
    rules: base.rules,
    status: base.status,
    challengeId: base.challengeId,
    participantId: base.participantId,
    checkStart: joinDay,
  );
}

void main() {
  tearDown(resetSession);

  test('참가 첫날 이전은 고를 수 없다', () async {
    final api = MockChalloryApi()..sessions.replaceRange(0, 1, [_lateJoiner()]);
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    await c.read(sessionProvider.future);
    expect(firstSelectableDay, 4);
    expect(c.read(selectedDayProvider), 4);
    c.read(selectedDayProvider.notifier).set(1);
    expect(c.read(selectedDayProvider), 4);
  });

  test('처음부터 참가한 세션은 1일째부터 고른다', () async {
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(MockChalloryApi())]);
    addTearDown(c.dispose);
    await c.read(sessionProvider.future);
    expect(firstSelectableDay, 1);
    c.read(selectedDayProvider.notifier).set(1);
    expect(c.read(selectedDayProvider), 1);
  });

  testWidgets('홈 날짜 띠: 참가 전 날은 눌러도 안 바뀌고 ✓ 표시도 없다', (tester) async {
    final api = MockChalloryApi()..sessions.replaceRange(0, 1, [_lateJoiner()]);
    final container = await pumpApp(tester, location: R.home, overrides: [apiProvider.overrideWithValue(api)]);
    expect(container.read(selectedDayProvider), 4);
    // 10/6 시작: 2일째 = 7일
    final day2 = find.ancestor(of: find.text('7'), matching: find.byType(InkWell)).first;
    expect(tester.widget<InkWell>(day2).onTap, isNull);
    await tester.tap(find.text('7'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(container.read(selectedDayProvider), 4);
    // 1~3일째에는 ✓ 가 없다(4일째 선택, 5~7일째는 미래)
    expect(find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.check_rounded && w.size == 12), findsNothing);
  });
}
