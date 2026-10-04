// 챌로리 점수 엔진 (Dart 포팅)
//
// 기준: docs/04-칼로리-엔진-및-순위-규칙.md §2~§5, prototype/data.js ENGINE.
// 서버 SQL 함수(supabase/migrations/*_engine.sql: activity_kcal · intake_kcal ·
// score_simulate · score_simulate_from_inputs)와 같은 입력에 같은 결과를 내야 한다.
// 앱은 이 값을 화면 미리보기(P5 잠정 표시·P7 확정 전·P11 시뮬레이터 오프라인)로만 쓰고,
// 순위에 들어가는 값은 항상 서버가 계산한다.
//
// 반올림 규칙(세 구현 공통): round1(x) = floor(x*10 + 0.5) / 10 (음수도 +∞ 방향 half-up,
// JS Math.round와 동일), round10(x) = floor(x/10 + 0.5) * 10.

import 'dart:math' as math;

import 'rules.dart';

export 'rules.dart';

enum Sex { m, f }

enum MealSlot { breakfast, lunch, dinner, snack }

const mainSlots = [MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner];

/// 05 meals.status 와 1:1. [empty]는 행이 없는 슬롯(시뮬레이터 입력용).
enum MealStatus { empty, captured, draft, failed, confirmed, auto, corrected, voided, skipped }

enum SessionType { running, stair, walking }

double round1(num x) => (x * 10 + 0.5).floorToDouble() / 10;
int round10(num x) => ((x / 10) + 0.5).floor() * 10;
double clampD(num x, num lo, num hi) => math.min(hi, math.max(lo, x)).toDouble();

class Profile {
  const Profile({required this.sex, required this.weightKg, required this.heightCm, required this.age});
  final Sex sex;
  final double weightKg;
  final double heightCm;
  final int age;
}

class BmrResult {
  const BmrResult(this.raw, this.bmr);
  final double raw;
  final int bmr;
}

class SessionInput {
  const SessionInput({
    required this.type,
    required this.minutes,
    this.distanceM,
    this.stepsInRange = 0,
    this.met,
    this.isCounted = true,
    this.manual = false,
  });
  final SessionType type;
  final double minutes;
  final double? distanceM;
  final int stepsInRange;

  /// 지정 시 속도 tier 대신 이 MET를 쓴다(프로토타입 호환·테스트용).
  final double? met;
  final bool isCounted;

  /// recordingMethod = MANUAL_ENTRY / WasUserEntered = true → 집계 제외(04 §3.3 T05).
  final bool manual;
}

class MealInput {
  const MealInput({required this.slot, required this.status, this.kcal = 0, this.aiKcal});
  final MealSlot slot;
  final MealStatus status;

  /// 확정값(confirmed_kcal). confirmed/auto/corrected 일 때만 의미가 있다.
  final double kcal;
  final double? aiKcal;
}

class ActivityResult {
  const ActivityResult({
    required this.stepsOut,
    required this.stepsNetKcal,
    required this.sessionsNetKcal,
    required this.floorsKcal,
    required this.aRaw,
    required this.aD,
    required this.aCapped,
    required this.sessionMets,
  });
  final int stepsOut;
  final double stepsNetKcal;
  final double sessionsNetKcal;
  final double floorsKcal;
  final double aRaw;
  final double aD;
  final bool aCapped;
  final List<double> sessionMets;

  /// 상한 초과로 반영되지 않은 kcal (P8 "상한 초과 nnn kcal 미반영").
  double get overCap => math.max(0, round1(aRaw - aD));
}

class DraftSlot {
  const DraftSlot(this.slot, this.value);
  final MealSlot slot;
  final double value;
}

class IntakeResult {
  const IntakeResult({
    required this.iD,
    required this.mP,
    required this.mainMealCount,
    required this.snackCount,
    required this.substituteSlots,
    required this.draftSlots,
    required this.pendingSlots,
    required this.skipsToday,
    required this.skipOver,
    this.substituteValues = const {},
  });
  final double iD;
  final double mP;
  final int mainMealCount;
  final int snackCount;
  final List<MealSlot> substituteSlots;
  final List<DraftSlot> draftSlots;
  final List<MealSlot> pendingSlots;
  final int skipsToday;
  final bool skipOver;

  /// 대체값을 더한 칸(빈 칸·분석 중 칸·한도 초과 건너뜀) → 쓴 값 max(M_p, 전날 같은 칸 kcal)(D61)
  final Map<MealSlot, double> substituteValues;

  /// [slot] 에 쓰는 대체값. 대체값이 없던 칸이면 M_p.
  double substituteFor(MealSlot slot) => substituteValues[slot] ?? mP;
}

/// 전날 장부 끼니 → 칸별 등록 kcal(확정·자동·정정만, 간식 칸 제외). 다음 날 대체값의 입력(D61).
Map<MealSlot, double> prevSlotKcal(Iterable<MealInput> meals) {
  final out = <MealSlot, double>{};
  for (final m in meals) {
    if (m.slot == MealSlot.snack) continue;
    if (m.status != MealStatus.confirmed && m.status != MealStatus.auto && m.status != MealStatus.corrected) continue;
    out[m.slot] = (out[m.slot] ?? 0) + m.kcal;
  }
  return out;
}

class ScoreResult {
  const ScoreResult({required this.fP, required this.floorApplied, required this.dD, required this.sD, required this.ratio});
  final double fP;
  final bool floorApplied;
  final double dD;
  final double sD;
  final double ratio;
}

class SimulateResult {
  const SimulateResult({required this.bmr, required this.bmrRaw, required this.activity, required this.intake, required this.score});
  final int bmr;
  final double? bmrRaw;
  final ActivityResult activity;
  final IntakeResult intake;
  final ScoreResult score;

  /// 소비 E_d = BMR + A_d
  double get e => round1(bmr + activity.aD);
}

class SimulateInput {
  const SimulateInput({
    this.profile,
    this.bmr,
    this.weightKg,
    this.stepsTotal = 0,
    this.sessions = const [],
    this.floors = 0,
    this.meals = const [],
    this.skipsUsedThisWeek = 0,
    this.prevSlots = const {},
  }) : assert(profile != null || (bmr != null && weightKg != null));
  final Profile? profile;

  /// profile 대신 잠금된 BMR(참가자 bmr_locked)과 체중을 직접 줄 수 있다.
  final int? bmr;
  final double? weightKg;
  final int stepsTotal;
  final List<SessionInput> sessions;
  final int floors;
  final List<MealInput> meals;
  final int skipsUsedThisWeek;

  /// 전날 칸별 등록 kcal([prevSlotKcal]). 비우면 대체값은 M_p.
  final Map<MealSlot, double> prevSlots;
}

class ChalloryEngine {
  const ChalloryEngine([this.rules = EngineRules.defaults]);
  final EngineRules rules;

  // ---------- §2 BMR ----------
  static BmrResult bmr(Profile p) {
    final raw = 10 * p.weightKg + 6.25 * p.heightCm - 5 * p.age + (p.sex == Sex.m ? 5 : -161);
    return BmrResult(raw, round10(raw));
  }

  /// BMR용 나이 = 시작 연도 − 출생 연도 (연도만 수집, 04 §6 예1: 1996 → 30).
  static int ageOnDate(int birthYear, DateTime date) => date.year - birthYear;

  /// 만 14세·19세 자격 판정은 12월 31일생으로 보수 적용(06 P2).
  static int ageConservative(int birthYear, DateTime date) => date.year - birthYear - 1;

  double m(int bmr) => math.max(rules.mMin, rules.mRatio * bmr);
  double f(int bmr) => math.max(rules.fMin, rules.fRatio * bmr);

  // ---------- §3 소비 ----------
  double kcalPerStep(double weightKg) => (rules.stepMet - 1) * weightKg / 6000;

  double runMet(double kmh) {
    // 반개구간 [하한, 상한) — 04 §3.3
    if (kmh >= 12.9) return 12.0;
    if (kmh >= 9.7) return 9.3;
    if (kmh >= 8.0) return 8.5;
    return 7.5;
  }

  /// 세션의 MET. 걷기 세션은 null(걸음 경로로만 처리).
  double? sessionMet(SessionInput s) {
    if (s.met != null) return s.met;
    switch (s.type) {
      case SessionType.walking:
        return null;
      case SessionType.stair:
        return rules.stairMet;
      case SessionType.running:
        final d = s.distanceM;
        if (d == null || d <= 0 || s.minutes <= 0) return 7.5; // 거리 없는 달리기
        // km/h = distance_m*60 / (minutes*1000) — SQL과 같은 연산 순서
        return runMet(d * 60 / (s.minutes * 1000));
    }
  }

  ActivityResult activity({required double weightKg, int stepsTotal = 0, List<SessionInput> sessions = const [], int floors = 0}) {
    var sessionSteps = 0;
    var sess = 0.0;
    final mets = <double>[];
    for (final s in sessions) {
      if (!s.isCounted || s.manual) continue;
      final met = sessionMet(s);
      if (met == null) continue; // 걷기 세션: 세션 net 0, 걸음 차감 없음(T04)
      sessionSteps += s.stepsInRange;
      sess += (met - 1) * weightKg * (s.minutes / 60);
      mets.add(met);
    }
    final stepsOut = math.min(math.max(0, stepsTotal - sessionSteps), rules.stepsCap);
    final steps = stepsOut * (rules.stepMet - 1) * weightKg / 6000;
    final fl = floors > 0 ? math.min(floors, rules.floorsCap) * (rules.stairMet - 1) * weightKg * rules.secPerFloor / 3600 : 0.0;
    final raw = steps + sess + fl;
    return ActivityResult(
      stepsOut: stepsOut,
      stepsNetKcal: round1(steps),
      sessionsNetKcal: round1(sess),
      floorsKcal: round1(fl),
      aRaw: round1(raw),
      aD: round1(math.min(raw, rules.c)),
      aCapped: raw > rules.c,
      sessionMets: mets,
    );
  }

  // ---------- §4.3 섭취 ----------
  static bool _isConfirmed(MealStatus s) => s == MealStatus.confirmed || s == MealStatus.auto || s == MealStatus.corrected;

  /// I_d. [provisional]=true면 draft 끼니를 max(M, 1.3×AI)로 잠정 산입(확정 배치의 자동 확정값과 같음).
  /// [prevSlots] 는 전날 칸별 등록 kcal: 빈 칸·분석 중 칸·한도 초과 건너뜀의 대체값은 max(M_p, 전날 같은 칸)(D61).
  IntakeResult intake({required int bmr, required List<MealInput> meals, int skipsUsedThisWeek = 0, Map<MealSlot, double> prevSlots = const {}}) {
    final mP = m(bmr);
    var i = 0.0;
    var mainCount = 0;
    var snacks = 0;
    var skipsToday = 0;
    var skipOver = false;
    final substituted = <MealSlot>[];
    final drafts = <DraftSlot>[];
    final pending = <MealSlot>[];
    final subValues = <MealSlot, double>{};

    for (final slot in mainSlots) {
      final inSlot = meals.where((x) => x.slot == slot).toList();
      var satisfied = false;
      var hasSkip = false;
      var hasPending = false;
      for (final meal in inSlot) {
        if (_isConfirmed(meal.status)) {
          i += meal.kcal;
          if (meal.kcal >= rules.snackKcal) {
            mainCount++;
            satisfied = true;
          } else {
            snacks++; // 간식 수준 확정 → 슬롯 미충족, kcal은 합산
          }
        } else if (meal.status == MealStatus.draft) {
          final v = math.max(mP, rules.autoConfirm * (meal.aiKcal ?? 0));
          i += v;
          mainCount++;
          satisfied = true;
          drafts.add(DraftSlot(slot, v));
        } else if (meal.status == MealStatus.skipped) {
          hasSkip = true;
        } else if (meal.status == MealStatus.captured || meal.status == MealStatus.failed) {
          hasPending = true;
        }
      }
      if (satisfied) continue;
      final sub = math.max(mP, prevSlots[slot] ?? 0);
      if (hasSkip) {
        // 건너뜀 한도: 1일 1회 · 주 3회, 초과분은 대체값
        if (skipsToday < rules.skipPerDay && skipsUsedThisWeek + skipsToday < rules.skipPerWeek) {
          skipsToday++;
          continue;
        }
        i += sub;
        subValues[slot] = sub;
        substituted.add(slot);
        skipOver = true;
        continue;
      }
      i += sub;
      subValues[slot] = sub;
      if (hasPending) {
        pending.add(slot);
      } else {
        substituted.add(slot);
      }
    }
    for (final meal in meals.where((x) => x.slot == MealSlot.snack && _isConfirmed(x.status))) {
      i += meal.kcal;
      snacks++;
    }
    return IntakeResult(
      iD: round1(i),
      mP: mP,
      mainMealCount: mainCount,
      snackCount: snacks,
      substituteSlots: substituted,
      draftSlots: drafts,
      pendingSlots: pending,
      skipsToday: skipsToday,
      skipOver: skipOver,
      substituteValues: subValues,
    );
  }

  /// 확정 배치의 자동 확정값 max(M_p, 1.3×AI)
  double autoConfirmValue(int bmr, double aiKcal) => math.max(m(bmr), rules.autoConfirm * aiKcal);

  // ---------- §5 점수 ----------
  ScoreResult score({required int bmr, required double aD, required double iD, required int mainMealCount}) {
    final fP = f(bmr);
    final iEff = math.max(iD, fP);
    final d = bmr + math.min(aD, rules.c) - iEff;
    final ratio = clampD(d / rules.t, 0, rules.sMax / 100);
    var s = 100 * ratio;
    if (mainMealCount == 0) s = 0;
    return ScoreResult(fP: fP, floorApplied: iD < fP, dD: round1(d), sD: round1(s), ratio: ratio);
  }

  SimulateResult simulate(SimulateInput input) {
    final BmrResult b = input.profile != null ? bmr(input.profile!) : BmrResult(double.nan, input.bmr!);
    final weight = input.profile?.weightKg ?? input.weightKg!;
    final act = activity(weightKg: weight, stepsTotal: input.stepsTotal, sessions: input.sessions, floors: input.floors);
    final inn = intake(bmr: b.bmr, meals: input.meals, skipsUsedThisWeek: input.skipsUsedThisWeek, prevSlots: input.prevSlots);
    final sc = score(bmr: b.bmr, aD: act.aD, iD: inn.iD, mainMealCount: inn.mainMealCount);
    return SimulateResult(bmr: b.bmr, bmrRaw: input.profile != null ? b.raw : null, activity: act, intake: inn, score: sc);
  }
}
