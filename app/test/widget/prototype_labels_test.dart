// 시안에서 남은 고정 문구(전수 점검 #12 #13 #14):
// 장부의 '[미결]' 칩, 결과 화면의 '28일 누적', 순위의 '20명씩 더 보기'(버튼 없음).
import 'package:challory/core/engine/engine.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

/// 31일짜리 월간 챌린지가 결과 발표 단계
class _PublishedMonthlyApi extends MockChalloryApi {
  _PublishedMonthlyApi() {
    final m = ChallengeSession.mockMonthly;
    sessions
      ..clear()
      ..add(ChallengeSession(challenge: m.challenge, me: m.me, rules: EngineRules.defaults, status: 'published', kind: 'monthly',
          challengeId: m.challengeId, participantId: m.participantId, checkStart: m.checkStart));
  }
}

void main() {
  tearDown(resetSession);

  testWidgets('#12 점수 장부: 미결 표식 칩이 없다', (tester) async {
    await pumpApp(tester, location: R.ledger);
    expect(find.textContaining('[미결]'), findsNothing);
    expect(find.textContaining('체중 비례 목표'), findsNothing);
    expect(find.textContaining('활동 상한 '), findsWidgets, reason: '다른 규칙 칩은 그대로');
  });

  testWidgets('#13 결과 발표: 링 아래 누적 일수는 챌린지 일수(31일)', (tester) async {
    await pumpApp(tester, overrides: [apiProvider.overrideWithValue(_PublishedMonthlyApi())]);
    expect(find.textContaining('31일 누적 · 최종'), findsOneWidget);
    expect(find.textContaining('28일 누적'), findsNothing);
  });

  testWidgets('#14 순위: 더 보기 버튼이 없으니 "20명씩 더 보기" 문구도 없다', (tester) async {
    await pumpApp(tester, location: R.rank);
    expect(find.textContaining('20명씩 더 보기'), findsNothing);
    expect(find.text('전체 42명'), findsOneWidget, reason: '모의 전체 42명');
  });
}
