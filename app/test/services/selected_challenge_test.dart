// 참가 목록·선택한 챌린지: 선택이 전역 세션(curChallenge)과 순위·장부를 바꾼다
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(resetSession);

  test('기본은 목록 첫 챌린지, 선택하면 그 챌린지', () async {
    final api = MockChalloryApi();
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    expect((await c.read(sessionProvider.future))!.challenge.name, '가을 걷기 챌린지');
    expect(curChallenge.name, '가을 걷기 챌린지');
    c.read(selectedChallengeProvider.notifier).select('mock-monthly');
    expect((await c.read(sessionProvider.future))!.challenge.name, '10월 챌린지');
    expect(curChallenge.name, '10월 챌린지');
  });

  test('선택이 바뀌면 순위를 다시 읽는다', () async {
    final api = MockChalloryApi();
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    await c.read(sessionProvider.future);
    c.listen(leaderboardProvider, (_, _) {});
    await c.read(leaderboardProvider.future);
    final before = api.calls.where((x) => x == 'leaderboard').length;
    c.read(selectedChallengeProvider.notifier).select('mock-monthly');
    await c.read(leaderboardProvider.future);
    expect(api.calls.where((x) => x == 'leaderboard').length, before + 1);
  });

  test('나가면 목록에서 빠지고 남은 챌린지가 선택된다', () async {
    final api = MockChalloryApi();
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    await c.read(sessionProvider.future);
    expect(await c.read(challengesActionsProvider).leave('mock-monthly'), isNull);
    expect((await c.read(sessionsProvider.future)).length, 1);
    expect((await c.read(sessionProvider.future))!.challenge.name, '가을 걷기 챌린지');
  });
}
