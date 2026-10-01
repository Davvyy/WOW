// 엔진 상수 (04 §5.2, 05 challenge_rules). 챌린지 공통·시작 후 잠금.
// 서버 challenge_rules 행을 읽으면 [EngineRules.fromJson]으로 덮어쓴다.

class EngineRules {
  const EngineRules({
    this.t = 500,
    this.c = 1000,
    this.sMax = 150,
    this.fMin = 1200,
    this.fRatio = 0.8,
    this.mMin = 700,
    this.mRatio = 0.45,
    this.autoConfirm = 1.3,
    this.snackKcal = 150,
    this.stepsCap = 30000,
    this.floorsCap = 50,
    this.stepMet = 3.8,
    this.stairMet = 6.8,
    this.secPerFloor = 17.5,
    this.skipPerDay = 1,
    this.skipPerWeek = 3,
    this.checkDays = 3,
    this.brothFactor = 0.6,
    this.nudgeMinM = 1500,
    this.nudgeMinF = 1200,
  });

  final double t;
  final double c;
  final double sMax;
  final double fMin;
  final double fRatio;
  final double mMin;
  final double mRatio;
  final double autoConfirm;
  final double snackKcal;
  final int stepsCap;
  final int floorsCap;
  final double stepMet;
  final double stairMet;
  final double secPerFloor;
  final int skipPerDay;
  final int skipPerWeek;
  final int checkDays;
  final double brothFactor;
  final double nudgeMinM;
  final double nudgeMinF;

  static const defaults = EngineRules();

  factory EngineRules.fromJson(Map<String, dynamic> j) {
    double d(String k, double v) => (j[k] as num?)?.toDouble() ?? v;
    int i(String k, int v) => (j[k] as num?)?.toInt() ?? v;
    const z = EngineRules.defaults;
    return EngineRules(
      t: d('t', z.t),
      c: d('c', z.c),
      fMin: d('f_min', z.fMin),
      fRatio: d('f_ratio', z.fRatio),
      mMin: d('m_min', z.mMin),
      mRatio: d('m_ratio', z.mRatio),
      autoConfirm: d('auto_confirm', z.autoConfirm),
      snackKcal: d('snack_kcal', z.snackKcal),
      stepsCap: i('steps_cap', z.stepsCap),
      floorsCap: i('floors_cap', z.floorsCap),
      stepMet: d('step_met', z.stepMet),
      stairMet: d('stair_met', z.stairMet),
      secPerFloor: d('sec_per_floor', z.secPerFloor),
      skipPerDay: i('skip_per_day', z.skipPerDay),
      skipPerWeek: i('skip_per_week', z.skipPerWeek),
      checkDays: i('check_days', z.checkDays),
      brothFactor: d('broth_factor', z.brothFactor),
      nudgeMinM: d('nudge_min_m', z.nudgeMinM),
      nudgeMinF: d('nudge_min_f', z.nudgeMinF),
    );
  }
}
