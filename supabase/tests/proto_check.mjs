// 프로토타입 엔진(prototype/data.js)으로 골든 케이스를 계산해 기대값과 비교한다.
// SQL·Dart·프로토타입 세 구현이 같은 값을 내는지 확인하는 보조 검사. 사용: node supabase/tests/proto_check.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import vm from 'node:vm';

const here = path.dirname(fileURLToPath(import.meta.url));
const ctx = { globalThis: {} };
ctx.window = undefined;
vm.createContext(ctx);
vm.runInContext(readFileSync(path.join(here, '../../prototype/data.js'), 'utf8').replace('typeof window !== \'undefined\' ? window : globalThis', 'globalThis'), ctx);
const { ENGINE } = ctx.globalThis.CHALLORY;
const cases = JSON.parse(readFileSync(path.join(here, 'golden_cases.json'), 'utf8')).cases;

const metOf = (s) => {
  if (s.type === 'walking') return null;
  if (s.type === 'stair') return 6.8;
  if (!s.distance_m || !s.minutes) return 7.5;
  return ENGINE.runMet(s.distance_m * 60 / (s.minutes * 1000));
};
let bad = 0, n = 0;
for (const c of cases) {
  const i = c.input;
  // 프로토타입은 슬롯당 1끼·세션 met 직접 입력 형식
  const sessions = (i.sessions || []).filter(s => s.recording_method !== 'MANUAL_ENTRY' && metOf(s) != null)
    .map(s => ({ met: metOf(s), minutes: s.minutes, steps: s.steps_in_range || 0 }));
  const meals = (i.meals || []).map(m => ({ slot: m.slot, status: m.status, kcal: m.kcal, aiKcal: m.ai_kcal }));
  const bmr = ENGINE.bmr({ sex: i.sex, weightKg: i.weight_kg, heightCm: i.height_cm, age: i.age }).bmr;
  const act = ENGINE.activity({ weightKg: i.weight_kg, stepsTotal: i.steps_total, sessions, floors: i.floors });
  const inn = ENGINE.intake({ bmr, meals, skipsUsedThisWeek: i.skips_used_this_week || 0 });
  const sc = ENGINE.score({ bmr, A: act.A, I: inn.I, confirmedMeals: inn.confirmedMeals });
  // steps_out: 프로토타입은 상한 전 값을 보고(04 §3.2 정의는 상한 후)이므로 상한을 씌워 비교
  const got = { bmr, a_d: act.A, a_raw: act.raw, steps_out: Math.min(act.stepsOut, ENGINE.CONST.STEPS_CAP), steps_net_kcal: act.stepsNet, sessions_net_kcal: act.sessionNet, steps_net_kcal: act.stepsNet, sessions_net_kcal: act.sessionNet,
    floors_kcal: act.floorsBonus, a_capped: act.capped, i_d: inn.I, m_p: inn.M, d_d: sc.D, s_d: sc.S, f_p: sc.F, floor_applied: sc.floorApplied,
    main_meal_count: inn.confirmedMeals, skip_over: inn.skipOver };
  for (const [k, v] of Object.entries(c.expect)) {
    n++;
    const g = got[k];
    const ok = typeof v === 'number' ? Math.abs(g - v) <= 0.05 : g === v;
    if (!ok) { bad++; console.log(`[FAIL] ${c.id}.${k} expected ${v} got ${g}`); }
  }
}
console.log(bad ? `[FAIL] prototype: ${bad}/${n}` : `[OK] prototype engine: ${n} assertions`);
process.exit(bad ? 1 : 0);
