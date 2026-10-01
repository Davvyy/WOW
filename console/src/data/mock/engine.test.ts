import { describe, expect, it } from 'vitest';
import { mockSimulate } from './engine';

describe('mock simulate (골든 값)', () => {
  it('예시 1: 폰만 70 kg 남 175 cm 30세, 9,000걸음, 420/780/600 → 28.8', () => {
    const r = mockSimulate({
      sex: 'M', weight_kg: 70, height_cm: 175, age: 30, steps_total: 9000, sessions: [], floors: 0,
      meals: [
        { slot: 'breakfast', status: 'confirmed', kcal: 420 },
        { slot: 'lunch', status: 'confirmed', kcal: 780 },
        { slot: 'dinner', status: 'confirmed', kcal: 600 },
      ],
    });
    expect(r.bmr).toBe(1650);
    expect(r.s_d).toBe(28.8);
    expect(r.activity.a_d).toBeCloseTo(294, 0);
  });

  it('예시 2: 워치 58 kg 여 163 cm 30세, 12,000걸음 + 달리기 30분 4.5 km, 380/520/450 → 72.1', () => {
    const r = mockSimulate({
      sex: 'F', weight_kg: 58, height_cm: 163, age: 30, steps_total: 12000, floors: 0,
      sessions: [{ type: 'running', minutes: 30, distance_m: 4500, steps_in_range: 4500 }],
      meals: [
        { slot: 'breakfast', status: 'confirmed', kcal: 380 },
        { slot: 'lunch', status: 'confirmed', kcal: 520 },
        { slot: 'dinner', status: 'confirmed', kcal: 450 },
      ],
    });
    expect(r.s_d).toBe(72.1);
  });

  it('예시 3: 1끼 600만 확정 → 0.0 (대체값 2끼)', () => {
    const r = mockSimulate({
      sex: 'M', weight_kg: 70, height_cm: 175, age: 30, steps_total: 9000, sessions: [], floors: 0,
      meals: [{ slot: 'dinner', status: 'confirmed', kcal: 600 }],
    });
    expect(r.s_d).toBe(0);
    expect(r.intake.substitute_slots).toEqual(['breakfast', 'lunch']);
  });
});
