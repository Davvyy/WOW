/**
 * [모의 전용] 점수 엔진 TS 포트 — prototype/data.js ENGINE과 같은 산식.
 * 실제 경로(supabase)는 서버 RPC `score_simulate_from_inputs`를 호출하며 이 파일을 쓰지 않는다.
 * 모의 데이터(시드·판정 미리보기·OP1 시뮬레이션)에만 쓴다.
 */
import type { SimInput, SimResult, Slot } from '../types';

export const RULES = {
  T: 500, C: 1000, S_MAX: 150, F_MIN: 1200, F_RATIO: 0.8, M_MIN: 700, M_RATIO: 0.45, AUTO_CONFIRM: 1.3,
  SNACK_KCAL: 150, STEPS_CAP: 30000, FLOORS_CAP: 50, SKIP_PER_DAY: 1, SKIP_PER_WEEK: 3,
  MET_WALK: 3.8, MET_STAIR: 6.8, SEC_PER_FLOOR: 17.5, CHECK_DAYS: 3,
  RUN_MET_TIERS: [
    { minKmh: 12.9, met: 12.0 },
    { minKmh: 9.7, met: 9.3 },
    { minKmh: 8.0, met: 8.5 },
    { minKmh: 0, met: 7.5 },
  ],
};

export const round1 = (x: number) => Math.round(x * 10) / 10;
const round10 = (x: number) => Math.round(x / 10) * 10;
const clamp = (x: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, x));

export function bmrOf(sex: 'M' | 'F', weightKg: number, heightCm: number, age: number): number {
  return round10(10 * weightKg + 6.25 * heightCm - 5 * age + (sex === 'M' ? 5 : -161));
}
export const mOf = (bmr: number) => Math.max(RULES.M_MIN, RULES.M_RATIO * bmr);
export const fOf = (bmr: number) => Math.max(RULES.F_MIN, RULES.F_RATIO * bmr);
const runMet = (kmh: number) => RULES.RUN_MET_TIERS.find((t) => kmh >= t.minKmh)!.met;

/** 걷기 세션은 MET 없음(걸음 경로만). 서버 session_met과 같다. */
function sessionMet(type: 'running' | 'stair' | 'walking', minutes: number, distanceM: number): number | null {
  if (type === 'stair') return RULES.MET_STAIR;
  if (type === 'walking') return null;
  if (minutes <= 0 || distanceM <= 0) return 7.5;
  const kmh = minutes > 0 ? (distanceM / 1000) / (minutes / 60) : 0;
  return runMet(kmh);
}

export function mockSimulate(input: SimInput): SimResult {
  const w = input.weight_kg;
  const bmr = input.bmr ?? bmrOf(input.sex ?? 'M', w, input.height_cm ?? 170, input.age ?? 30);

  // 활동
  const counted = input.sessions.map((s) => ({ s, met: sessionMet(s.type, s.minutes, s.distance_m) })).filter((x) => x.met != null);
  const sessionSteps = counted.reduce((a, x) => a + (x.s.steps_in_range || 0), 0);
  const stepsOut = Math.min(Math.max(0, input.steps_total - sessionSteps), RULES.STEPS_CAP);
  const stepsNet = stepsOut * (RULES.MET_WALK - 1) * w / 6000;
  const sessNet = counted.reduce((a, x) => a + ((x.met as number) - 1) * w * (x.s.minutes / 60), 0);
  const floorsKcal = input.floors > 0 ? Math.min(input.floors, RULES.FLOORS_CAP) * (RULES.MET_STAIR - 1) * w * RULES.SEC_PER_FLOOR / 3600 : 0;
  const aRaw = stepsNet + sessNet + floorsKcal;
  const aD = Math.min(aRaw, RULES.C);

  // 섭취
  const M = mOf(bmr);
  const mains: Slot[] = ['breakfast', 'lunch', 'dinner'];
  let I = 0, mainCount = 0, snacks = 0, skipsToday = 0;
  const substitute: string[] = [], pending: string[] = [], drafts: { slot: string; value: number }[] = [];
  for (const slot of mains) {
    const m = input.meals.find((x) => x.slot === slot);
    if (!m || m.status === 'empty') { I += M; substitute.push(slot); continue; }
    if (m.status === 'skipped') {
      if (skipsToday < RULES.SKIP_PER_DAY) { skipsToday++; continue; }
      I += M; substitute.push(slot); continue;
    }
    if (m.status === 'void') { I += M; substitute.push(slot); continue; }
    if (m.status === 'confirmed' || m.status === 'auto' || m.status === 'corrected') {
      const k = m.kcal ?? 0;
      if (k >= RULES.SNACK_KCAL) { I += k; mainCount++; } else { I += k + M; substitute.push(slot); snacks++; }
      continue;
    }
    if (m.status === 'draft') {
      const v = Math.max(M, RULES.AUTO_CONFIRM * (m.ai_kcal ?? 0));
      I += v; mainCount++; drafts.push({ slot, value: v }); continue;
    }
    I += M; pending.push(slot);
  }
  for (const m of input.meals.filter((x) => x.slot === 'snack' && (x.status === 'confirmed' || x.status === 'auto' || x.status === 'corrected'))) { I += m.kcal ?? 0; snacks++; }

  // 점수
  const F = fOf(bmr);
  const D = bmr + Math.min(aD, RULES.C) - Math.max(I, F);
  let S = 100 * clamp(D / RULES.T, 0, RULES.S_MAX / 100);
  if (mainCount === 0) S = 0;

  return {
    bmr, m_p: M, f_p: F,
    activity: { steps_out: stepsOut, steps_net_kcal: round1(stepsNet), sessions_net_kcal: round1(sessNet), floors_kcal: round1(floorsKcal), a_raw: round1(aRaw), a_d: round1(aD), a_capped: aRaw > RULES.C },
    intake: { i_d: round1(I), main_meal_count: mainCount, snack_count: snacks, substitute_slots: substitute, draft_slots: drafts, pending_slots: pending },
    d_d: round1(D),
    s_d: round1(S),
    floor_applied: I < F,
  };
}
