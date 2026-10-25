// 규칙(P11) 문구: 간식 기준 0(D59)이면 '간식은 찍은 만큼' · 시뮬레이터 설명에 화면 번호 없음 · 활동 kcal 은 정수
import 'package:challory/core/engine/engine.dart';
import 'package:challory/data/mock/mock_data.dart';
import 'package:challory/router.dart';
import 'package:challory/services/api/mock_api.dart';
import 'package:challory/state/app_state.dart';
import 'package:challory/state/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show pumpApp;

class _Snack0 extends MockChalloryApi {
  _Snack0() {
    sessions[0] = ChallengeSession(challenge: mockChallenge, me: mockMe, rules: EngineRules(snackKcal: 0), status: 'running',
        challengeId: 'mock-challenge', participantId: 'mock-p');
  }
}

void main() {
  tearDown(resetSession);

  testWidgets('간식 기준 0: 카드 ① 아래 "간식은 찍은 만큼"(0 미만 문구 없음)', (tester) async {
    await pumpApp(tester, location: R.rules, overrides: [apiProvider.overrideWithValue(_Snack0())]);
    expect(find.textContaining('· 간식은 찍은 만큼'), findsOneWidget);
    expect(find.textContaining('간식 0 미만'), findsNothing);
  });

  testWidgets('시뮬레이터: 화면 번호(P5·P10) 대신 화면 이름, 활동 kcal 은 정수', (tester) async {
    await pumpApp(tester, location: R.rules);
    expect(find.textContaining('P5·P10'), findsNothing);
    expect(find.textContaining('홈·점수 계산 화면과 같은 산식'), findsOneWidget);
    expect(find.textContaining(RegExp(r'활동 [\d,]+\.\d · 순적자')), findsNothing);
    expect(find.textContaining(RegExp(r'^활동 [\d,]+ · 순적자')), findsOneWidget);
  });
}
