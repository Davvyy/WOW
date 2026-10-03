// 처음 참가: 이번 달 챌린지(코드 없이) → 프로필·동의 → 월간 참가
import 'package:challory/core/engine/engine.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('월간 참가를 고르면 열린 월간 챌린지 id 로 참가', () async {
    final api = MockChalloryApi()..sessions.clear();
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final ob = c.read(onboardingProvider.notifier);
    ob.chooseMonthly();
    ob.setProfile(nickname: '지수', sex: Sex.m, birthYear: 1996, heightCm: 175, weightKg: 70, pregnancy: false, eatingDisorder: false,
        sensitiveHealth: true);
    expect(await ob.join(terms: true, overseasAi: true), isNull);
    expect(api.lastJoin!.challengeId, 'mock-monthly');
    expect(api.lastJoin!.code, isNull);
  });

  test('참가할 월간이 없으면 안내', () async {
    final api = MockChalloryApi(); // 이미 월간 참가 중 → myStatus active
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final ob = c.read(onboardingProvider.notifier)..chooseMonthly();
    ob.setProfile(nickname: '지수', sex: Sex.m, birthYear: 1996, heightCm: 175, weightKg: 70, pregnancy: false, eatingDisorder: false,
        sensitiveHealth: true);
    expect(await ob.join(terms: true, overseasAi: true), '지금 참가할 수 있는 이번 달 챌린지가 없어요');
  });
}
