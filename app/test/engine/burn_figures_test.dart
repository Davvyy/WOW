// 소비(추정) 표시값: 홈과 활동 탭이 같은 계산·같은 반올림(정수 kcal)을 쓴다.
import 'package:challory/core/burn.dart';
import 'package:challory/core/engine/engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = ChalloryEngine(EngineRules.defaults);
  SimulateResult sim({int steps = 0, List<SessionInput> sessions = const [], int floors = 0}) =>
      engine.simulate(SimulateInput(bmr: 1820, weightKg: 70, stepsTotal: steps, sessions: sessions, floors: floors));

  test('걸음 활동 530.2 → 활동 530, 소비 = BMR + 활동 = 2,350', () {
    // 70 kg · 걸음 16,230 → 530.2 kcal(소수 1자리)
    final s = sim(steps: 16230);
    expect(s.activity.aD, 530.2);
    final b = BurnFigures.of(s);
    expect(b.bmr, 1820);
    expect(b.steps, 530);
    expect(b.activity, 530);
    expect(b.total, 2350);
    expect(b.total, b.bmr + b.activity);
  });

  test('0.5 는 올림(half-up): 활동과 소비가 함께 올라간다', () {
    final s = SimulateResult(
      bmr: 1820,
      bmrRaw: null,
      activity: const ActivityResult(stepsOut: 0, stepsNetKcal: 530.5, sessionsNetKcal: 0, floorsKcal: 0, aRaw: 530.5, aD: 530.5, aCapped: false, sessionMets: []),
      intake: sim().intake,
      score: sim().score,
    );
    final b = BurnFigures.of(s);
    expect(b.activity, 531);
    expect(b.total, 2351);
    expect(b.total, (s.e + 0.5).floor(), reason: '엔진 소비 e 를 반올림한 값과 같다');
  });

  test('상한(1,000)에 걸리면 활동은 상한값, 세션·층수도 정수', () {
    final s = sim(steps: 30000, sessions: const [SessionInput(type: SessionType.running, minutes: 30, distanceM: 4500, stepsInRange: 4500)], floors: 10);
    final b = BurnFigures.of(s);
    expect(s.activity.aCapped, isTrue);
    expect(b.activity, 1000);
    expect(b.total, 2820);
    expect(b.sessions, (s.activity.sessionsNetKcal + 0.5).floor());
    expect(b.floors, (s.activity.floorsKcal + 0.5).floor());
  });
}
