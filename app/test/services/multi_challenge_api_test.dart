// 모의 API: 참가 목록 2개(월간 + 운영자), 열린 월간 참가, 나가기, 자동 참가, 동시 3개
import 'package:challory/core/engine/engine.dart';
import 'package:challory/services/api/challory_api.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

JoinRequest monthly(String id) => JoinRequest(challengeId: id, nickname: '지수', sex: Sex.m, birthYear: 1996, heightCm: 175, weightKg: 70,
    terms: true, sensitiveHealth: true, overseasAi: true);

void main() {
  test('참가 목록: 운영자 챌린지와 월간(모의 순서: 가을 걷기 먼저 — 기존 화면 테스트의 기본 챌린지 유지)', () async {
    final api = MockChalloryApi();
    final list = await api.fetchSessions();
    expect(list.map((s) => s.challenge.name), ['가을 걷기 챌린지', '10월 챌린지']);
    expect(list.last.monthly, isTrue);
    expect(list.map((s) => s.challengeId).toSet().length, 2);
  });

  test('나가면 목록에서 빠지고 같은 챌린지는 다시 참가할 수 없다', () async {
    final api = MockChalloryApi();
    await api.leaveChallenge('mock-monthly');
    expect((await api.fetchSessions()).map((s) => s.challengeId), ['mock-challenge']);
    final open = await api.fetchOpenChallenges();
    expect(open.single.myStatus, 'left');
    expect(() => api.joinChallenge(monthly('mock-monthly')), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));
  });

  test('열린 월간에 코드 없이 참가 → 목록 맨 앞', () async {
    final api = MockChalloryApi()..sessions.removeWhere((s) => s.challengeId == 'mock-monthly');
    expect((await api.fetchOpenChallenges()).single.myStatus, isNull);
    final r = await api.joinChallenge(monthly('mock-monthly'));
    expect(r.kind, 'monthly');
    expect((await api.fetchSessions()).first.challengeId, 'mock-monthly');
  });

  test('동시 3개를 넘으면 거절', () async {
    final api = MockChalloryApi();
    final again = await api.joinChallenge(JoinRequest(code: 'K7Q2MD', nickname: '지수', sex: Sex.m, birthYear: 1996, heightCm: 175, weightKg: 70,
        terms: true, sensitiveHealth: true, overseasAi: true));
    expect(again.challengeId, 'mock-challenge', reason: '이미 참가 중이면 그대로(멱등)');
    expect(api.sessions.length, 2);
    api.sessions
      ..removeWhere((s) => s.challengeId == 'mock-monthly')
      ..addAll([ChallengeSession.mock, ChallengeSession.mock]); // 월간 없이 3개
    expect(api.sessions.length, 3);
    expect(() => api.joinChallenge(monthly('mock-monthly')), throwsA(isA<ApiException>().having((e) => e.status, 'status', 409)));
  });

  test('다음 달 자동 참가: 기본 켬, 끄고 다시 읽기', () async {
    final api = MockChalloryApi();
    expect(await api.fetchAutoContinue(), isTrue);
    await api.setAutoContinue(false);
    expect(await api.fetchAutoContinue(), isFalse);
  });
}
