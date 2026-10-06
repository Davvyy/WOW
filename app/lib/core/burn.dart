import 'engine/engine.dart';

/// 소비(추정) 표시값. 홈(숫자 셋·활동 카드)과 활동 탭(소비 분해)이 같은 계산·같은 반올림을 쓰게 한 곳에서 만든다.
/// kcal 은 모두 정수(half-up, [fmtInt] 와 같은 규칙)로 보인다. 소비 = BMR + 활동이라 화면의 두 숫자를 더하면 소비와 맞는다
/// (BMR 은 정수라 엔진 소비 e = round1(BMR + 활동) 을 반올림한 값과도 같다).
class BurnFigures {
  const BurnFigures._({required this.bmr, required this.activity, required this.steps, required this.sessions, required this.floors});

  factory BurnFigures.of(SimulateResult sim) {
    final a = sim.activity;
    return BurnFigures._(bmr: sim.bmr, activity: _round(a.aD), steps: _round(a.stepsNetKcal), sessions: _round(a.sessionsNetKcal), floors: _round(a.floorsKcal));
  }

  static int _round(num x) => (x + 0.5).floor();

  final int bmr;

  /// 소비에 들어간 활동 kcal(상한 적용 뒤)
  final int activity;

  /// 소비 분해의 걸음·운동 세션·층수 kcal(상한 적용 전 각 몫)
  final int steps;
  final int sessions;
  final int floors;

  /// 소비(추정) = BMR + 활동
  int get total => bmr + activity;
}
