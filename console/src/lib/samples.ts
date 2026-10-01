import type { SimInput } from '../data/types';

/** OP1 샘플 3명 (05 API #25 골든 3건). 입력은 서버 RPC 계약 모양과 같다. */
export interface Sample { key: string; label: string; sub: string; input: SimInput }

export const SAMPLES: Sample[] = [
  {
    key: 'phone', label: '폰만 70 kg 남', sub: '예시 1 · Galaxy · 걸음 9,000 · 세 끼 확정',
    input: {
      sex: 'M', weight_kg: 70, height_cm: 175, age: 30, steps_total: 9000, sessions: [], floors: 0,
      meals: [{ slot: 'breakfast', status: 'confirmed', kcal: 420, ai_kcal: 450 }, { slot: 'lunch', status: 'confirmed', kcal: 780, ai_kcal: 850 }, { slot: 'dinner', status: 'confirmed', kcal: 600, ai_kcal: 640 }],
    },
  },
  {
    key: 'watch', label: '워치 58 kg 여', sub: '예시 2 · Apple Watch · 걸음 12,000 + 달리기 30분',
    input: {
      sex: 'F', weight_kg: 58, height_cm: 163, age: 30, steps_total: 12000, floors: 0,
      sessions: [{ type: 'running', minutes: 30, distance_m: 4500, steps_in_range: 4500 }],
      meals: [{ slot: 'breakfast', status: 'confirmed', kcal: 380 }, { slot: 'lunch', status: 'confirmed', kcal: 520 }, { slot: 'dinner', status: 'confirmed', kcal: 450 }],
    },
  },
  {
    key: 'one', label: '1끼 600만 확정', sub: '대체값·하한 검증 · 걸음 9,000 · 저녁만 확정',
    input: {
      sex: 'M', weight_kg: 70, height_cm: 175, age: 30, steps_total: 9000, sessions: [], floors: 0,
      meals: [{ slot: 'dinner', status: 'confirmed', kcal: 600 }],
    },
  },
];
