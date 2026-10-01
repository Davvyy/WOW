/**
 * [모의 전용] prototype/data.js · console.html 예시 데이터 시드.
 * 가을 걷기 챌린지 10.6~11.2, 42/60명, 오늘 10.13(D+8), 지수 = 운영자 콘솔에서 보는 참가자 중 한 명.
 */
import type { HealthAlertType, Slot } from '../types';

export interface MockMeal { slot: Slot; status: 'confirmed' | 'empty' | 'void' | 'draft' | 'skipped'; kcal?: number; ai_kcal?: number }
export interface MockSession { type: 'running' | 'stair' | 'walking'; minutes: number; distance_m: number; steps_in_range: number }
export interface MockDayInput { date: string; steps: number; sessions: MockSession[]; meals: MockMeal[] }

export interface MockPersonSeed {
  name: string; sex: 'M' | 'F'; birthYear: number; heightCm: number; weightKg: number;
  device: string; source: string; platform: string; watch?: boolean;
  baseSteps: number; spikeDay?: number; spikeSteps?: number; mealScale?: number; lowIntakeDays?: number[];
  warns: number; mealsToday: number; syncAt?: string; lastSync?: string; zeroFrom?: number;
  unsynced?: boolean; recordReason?: string; staticCum?: number;
}

export const START = '2026-10-06';
export const DATES = ['2026-10-06', '2026-10-07', '2026-10-08', '2026-10-09', '2026-10-10', '2026-10-11', '2026-10-12', '2026-10-13'];

export const PEOPLE_SEED: MockPersonSeed[] = [
  { name: '달려라하니', sex: 'F', birthYear: 1992, heightCm: 165, weightKg: 57, device: 'iPhone + Apple Watch', source: 'Apple 건강', platform: 'HealthKit', watch: true, baseSteps: 12400, spikeDay: 7, spikeSteps: 28400, mealScale: 0.8, warns: 0, mealsToday: 3, syncAt: '21:05', staticCum: 486.2 },
  { name: '강남콩', sex: 'M', birthYear: 1990, heightCm: 178, weightKg: 76, device: 'Galaxy', source: '삼성헬스', platform: 'Health Connect', baseSteps: 11800, warns: 0, mealsToday: 3, syncAt: '21:10', staticCum: 451.0 },
  { name: '밤산책', sex: 'F', birthYear: 1996, heightCm: 163, weightKg: 58, device: 'iPhone + Apple Watch', source: 'Apple 건강', platform: 'HealthKit', watch: true, baseSteps: 11500, lowIntakeDays: [4, 5, 6], warns: 0, mealsToday: 3, syncAt: '20:58', staticCum: 388.7 },
  { name: '지수', sex: 'M', birthYear: 1996, heightCm: 175, weightKg: 70, device: 'Galaxy', source: '삼성헬스', platform: 'Health Connect', baseSteps: 9000, warns: 0, mealsToday: 3, syncAt: '21:10' },
  { name: '오이냉국', sex: 'F', birthYear: 1988, heightCm: 160, weightKg: 62, device: 'Galaxy', source: '삼성헬스', platform: 'Health Connect', baseSteps: 7600, warns: 2, mealsToday: 2, syncAt: '20:40', staticCum: 301.9 },
  { name: '초록이', sex: 'M', birthYear: 1999, heightCm: 172, weightKg: 68, device: 'iPhone', source: 'Apple 건강', platform: 'HealthKit', baseSteps: 10200, warns: 0, mealsToday: 3, syncAt: '21:00' },
  { name: '라떼한잔', sex: 'F', birthYear: 1995, heightCm: 158, weightKg: 54, device: 'Galaxy', source: '삼성헬스', platform: 'Health Connect', baseSteps: 6900, unsynced: true, lastSync: '10.12 22:40', zeroFrom: 8, warns: 0, mealsToday: 1, staticCum: 268.4 },
  { name: '마포구민', sex: 'M', birthYear: 1985, heightCm: 174, weightKg: 80, device: 'Galaxy', source: '삼성헬스', platform: 'Health Connect', baseSteps: 8400, warns: 1, mealsToday: 2, syncAt: '19:30', staticCum: 251.0 },
  { name: '야근요정', sex: 'F', birthYear: 1993, heightCm: 162, weightKg: 55, device: 'Galaxy', source: '삼성헬스', platform: 'Health Connect', baseSteps: 7200, unsynced: true, lastSync: '10.12 19:05', zeroFrom: 8, warns: 0, mealsToday: 2, staticCum: 236.5 },
  { name: '새벽커피', sex: 'F', birthYear: 2001, heightCm: 167, weightKg: 49, device: 'iPhone', source: 'Apple 건강', platform: 'HealthKit', baseSteps: 6800, recordReason: 'BMI 17.6 (18.5 미만) · 안전 체크 해당 · P2 기록 모드 안내에 동의(10.5)', warns: 0, mealsToday: 3, syncAt: '21:02' },
  { name: '한강러너', sex: 'M', birthYear: 1997, heightCm: 180, weightKg: 73, device: 'Galaxy', source: '삼성헬스', platform: 'Health Connect', baseSteps: 13100, unsynced: true, lastSync: '10.11 23:50', zeroFrom: 7, warns: 0, mealsToday: 0 },
  { name: '도토리', sex: 'M', birthYear: 1994, heightCm: 170, weightKg: 66, device: 'Galaxy', source: '삼성헬스', platform: 'Health Connect', baseSteps: 11300, warns: 0, mealsToday: 3, syncAt: '21:08' },
];

const c = (kcal: number): MockMeal => ({ slot: 'breakfast', status: 'confirmed', kcal });
const slots: Slot[] = ['breakfast', 'lunch', 'dinner'];
const withSlots = (ms: MockMeal[]) => ms.map((m, i) => ({ ...m, slot: slots[i] }));
const empty = (): MockMeal => ({ slot: 'breakfast', status: 'empty' });

export const TODAY_MEALS: MockMeal[] = [
  { slot: 'breakfast', status: 'confirmed', kcal: 420, ai_kcal: 450 },
  { slot: 'lunch', status: 'confirmed', kcal: 780, ai_kcal: 850 },
  { slot: 'dinner', status: 'confirmed', kcal: 600, ai_kcal: 640 },
];
export const TODAY_MEAL_TITLES: Record<string, string> = { dinner: '닭가슴살 샐러드 · 고구마' };

const ME_INPUT: { steps: number; meals: MockMeal[] }[] = [
  { steps: 9480, meals: withSlots([c(430), c(720), c(610)]) },
  { steps: 11200, meals: withSlots([c(400), c(810), c(590)]) },
  { steps: 9200, meals: withSlots([empty(), c(780), c(650)]) },
  { steps: 10806, meals: withSlots([c(410), c(690), c(460)]) },
  { steps: 12321, meals: withSlots([c(430), c(780), c(410)]) },
  { steps: 9000, meals: withSlots([c(300), c(480), c(370)]) },
  { steps: 10898, meals: withSlots([c(420), c(780), c(600)]) },
  { steps: 9000, meals: TODAY_MEALS.map((m) => ({ ...m })) },
];

/** 참가자별 8일 입력. 지수는 data.js 장부와 같고, 나머지는 prototype genLedger와 같은 규칙으로 만든다. */
export function buildDays(p: MockPersonSeed, i: number): MockDayInput[] {
  if (p.name === '지수') {
    return ME_INPUT.map((r, k) => ({ date: DATES[k], steps: r.steps, sessions: [], meals: r.meals.map((m) => ({ ...m })) }));
  }
  return DATES.map((date, k) => {
    const d = k + 1;
    let steps = Math.round(p.baseSteps * (0.86 + ((i * 7 + d * 13) % 9) / 32) / 10) * 10;
    if (p.spikeDay === d && p.spikeSteps) steps = p.spikeSteps;
    if (p.zeroFrom && d >= p.zeroFrom) steps = 0;
    let sessions: MockSession[] = [];
    const kc = [360 + ((i * 3 + d * 5) % 6) * 20, 640 + ((i * 5 + d * 7) % 8) * 25, 500 + ((i * 2 + d * 11) % 7) * 20];
    let meals: MockMeal[] = kc.map((k2, si) => ({ slot: slots[si], status: 'confirmed' as const, kcal: k2 }));
    if (p.mealScale) meals = meals.map((m) => ({ ...m, kcal: Math.round((m.kcal ?? 0) * p.mealScale! / 10) * 10 }));
    if (p.lowIntakeDays?.includes(d)) meals = meals.map((m) => ({ ...m, kcal: Math.round((m.kcal ?? 0) * 0.55 / 10) * 10 }));
    if (d === 8) meals = meals.map((m, si) => (si < p.mealsToday ? m : { slot: m.slot, status: 'empty' as const }));
    if (p.name === '밤산책' && d === 8) {
      steps = 12000;
      sessions = [{ type: 'running', minutes: 30, distance_m: 4500, steps_in_range: 4500 }];
      meals = [
        { slot: 'breakfast', status: 'confirmed', kcal: 380 },
        { slot: 'lunch', status: 'confirmed', kcal: 520 },
        { slot: 'dinner', status: 'confirmed', kcal: 450 },
      ];
    }
    return { date, steps, sessions, meals };
  });
}

export const HEALTH_SEED: { id: string; who: string; type: HealthAlertType; localDate: string; text: string; nudge: string }[] = [
  { id: 'H-1', who: '밤산책', type: 'low_intake_3d', localDate: '2026-10-11', text: '섭취 기록 3일 연속 적음(10.9~10.11)', nudge: '넛지 발송됨 · 10.12 09:10 (N-07)' },
  { id: 'H-2', who: '강남콩', type: 'high_activity_3d', localDate: '2026-10-12', text: '활동 기록 3일 연속 높음(10.10~10.12, 약 1,000 kcal 초과)', nudge: '넛지 발송됨 · 10.13 09:10 (N-07)' },
];

export const LEADERBOARD_OTHERS: { name: string; score: number }[] = [
  { name: '달려라하니', score: 486.2 }, { name: '강남콩', score: 451.0 }, { name: '밤산책', score: 388.7 },
  { name: '오이냉국', score: 301.9 }, { name: '새벽러닝', score: 301.9 }, { name: '라떼한잔', score: 268.4 },
  { name: '마포구민', score: 251.0 }, { name: '야근요정', score: 236.5 },
];

export const FINAL_SEED = [
  { rank: 1, name: '달려라하니', score: 1310.4, meals: 84 },
  { rank: 2, name: '강남콩', score: 1254.0, meals: 82 },
  { rank: 3, name: '밤산책', score: 1102.7, meals: 84 },
  { rank: 4, name: '지수', score: 1041.3, meals: 83 },
  { rank: 5, name: '초록이', score: 988.0, meals: 79 },
];

export const AUDIT_SEED: [string, string, string][] = [
  ['10.13 21:02', '민호', '검토 R-0412 소명 열람'],
  ['10.13 20:48', '민호', '검토 R-0415 사진 서명 URL 발급(10분) · 열람'],
  ['10.13 13:41', '시스템', '신고 접수 → R-0417 생성 · SLA 72h'],
  ['10.13 09:00', '시스템', '10.12 확정 배치 · is_final · 플래그 2건 → R-0412 · R-0415'],
];

export interface MockReviewSeed {
  id: string; shortId: string; type: 'steps_spike' | 'dup_photo' | 'report'; who: string; localDate: string; slot: Slot | null;
  status: 'open' | 'appealed'; slaHours: number; reason: 'steps_spike' | 'dup_photo' | null;
  appeal?: string; appealAt?: string; report?: string; reportAt?: string;
}
export const REVIEW_SEED: MockReviewSeed[] = [
  { id: 'rv-0412', shortId: 'R-0412', type: 'steps_spike', who: '달려라하니', localDate: '2026-10-12', slot: null, status: 'appealed', slaHours: 41, reason: 'steps_spike', appeal: '10.12에 하프마라톤 대회(21.1 km)에 나갔어요. 워치에서 운동으로 기록된 2시간 3분 세션 화면을 함께 보내요. 평소보다 많이 걸은 날이 맞아요.', appealAt: '10.13 08:12' },
  { id: 'rv-0415', shortId: 'R-0415', type: 'dup_photo', who: '지수', localDate: '2026-10-12', slot: 'dinner', status: 'open', slaHours: 44, reason: 'dup_photo' },
  { id: 'rv-0417', shortId: 'R-0417', type: 'report', who: '오이냉국', localDate: '2026-10-13', slot: 'lunch', status: 'open', slaHours: 60, reason: null, report: '10.13 점심 사진이 음식이 아니라 메뉴판 사진 같아요. 확인 부탁드려요.', reportAt: '10.13 13:40' },
];
