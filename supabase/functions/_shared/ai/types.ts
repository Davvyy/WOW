// 식사 사진 분석 어댑터 계약 (docs/04 §4.1, docs/05 §6)
// LLM은 음식명 후보·개수·분량 구간까지만 낸다. kcal·g 숫자는 출력하지 않고 식약처 DB(4.2)로 계산한다.

export type PortionBucket = 'half' | 'one' | 'large';
export type Confidence = 'high' | 'mid' | 'low';

export interface MealItemDraft {
  name_candidates: [string, string, string] | string[]; // 한국어 표준 음식명 top-3(확신 순)
  count: number; // ≥1
  portion_bucket: PortionBucket;
  has_broth: boolean;
  confidence: Confidence;
}

export interface MealAnalysis {
  is_food: boolean | null; // false → 검색 폴백, null → 분석 실패
  items: MealItemDraft[]; // ≤ 8
}

export interface MealImage {
  bytes: Uint8Array;
  mimeType: 'image/jpeg' | 'image/png' | 'image/webp';
}

export interface MealVisionAdapter {
  readonly engine: 'gemini' | 'claude' | 'mock';
  analyze(image: MealImage, opts: { signal: AbortSignal }): Promise<unknown>; // 원시 JSON(검증 전)
}

// 프롬프트 [제안] 04 §4.1: 한식 분류 체계 제시, kcal·g 숫자 출력 금지, 스키마 강제
export const MEAL_PROMPT = [
  '사진 속 음식을 한국어 표준 음식명으로 식별하세요. 밥·국/찌개/탕·반찬·김치·면·빵·음료·과일 단위로 나눕니다.',
  '각 항목마다 가능성 높은 이름 3개(name_candidates), 개수(count), 1인분 대비 분량(portion_bucket: half/one/large),',
  '국물 음식 여부(has_broth), 확신도(confidence: high/mid/low)를 내세요.',
  '칼로리나 그램 같은 숫자는 절대 출력하지 마세요. 음식이 아니면 is_food=false, items=[].',
  'JSON 스키마에 맞는 JSON 하나만 출력하세요.',
].join(' ');

// JSON Schema (Gemini responseSchema·Claude tool input_schema 공용)
export const MEAL_SCHEMA = {
  type: 'object',
  properties: {
    is_food: { type: 'boolean' },
    items: {
      type: 'array',
      maxItems: 8,
      items: {
        type: 'object',
        properties: {
          name_candidates: { type: 'array', items: { type: 'string' }, minItems: 1, maxItems: 3 },
          count: { type: 'integer', minimum: 1 },
          portion_bucket: { type: 'string', enum: ['half', 'one', 'large'] },
          has_broth: { type: 'boolean' },
          confidence: { type: 'string', enum: ['high', 'mid', 'low'] },
        },
        required: ['name_candidates', 'count', 'portion_bucket', 'has_broth', 'confidence'],
      },
    },
  },
  required: ['is_food', 'items'],
} as const;

export class SchemaError extends Error {}

const NUMBER_WITH_UNIT = /\d+\s*(kcal|칼로리|g|그램)/i;

/** 원시 응답을 04 §4.1 스키마로 검증·정규화. 위반 시 SchemaError. */
export function parseMealAnalysis(raw: unknown): MealAnalysis {
  const obj = typeof raw === 'string' ? JSON.parse(stripFence(raw)) : raw;
  if (!obj || typeof obj !== 'object') throw new SchemaError('not an object');
  const o = obj as Record<string, unknown>;
  if (typeof o.is_food !== 'boolean') throw new SchemaError('is_food must be boolean');
  if (!Array.isArray(o.items)) throw new SchemaError('items must be array');
  if (!o.is_food) return { is_food: false, items: [] };
  const items = o.items.slice(0, 8).map((it, i): MealItemDraft => {
    const x = it as Record<string, unknown>;
    const names = Array.isArray(x.name_candidates)
      ? x.name_candidates.filter((n): n is string => typeof n === 'string' && n.trim() !== '').map((n) => n.trim())
      : [];
    if (names.length === 0) throw new SchemaError(`items[${i}].name_candidates empty`);
    if (names.some((n) => NUMBER_WITH_UNIT.test(n))) throw new SchemaError(`items[${i}] contains kcal/g numbers`);
    const count = Number.isInteger(x.count) && (x.count as number) >= 1 ? (x.count as number) : 1;
    const bucket = ['half', 'one', 'large'].includes(x.portion_bucket as string) ? x.portion_bucket as PortionBucket : 'one';
    const conf = ['high', 'mid', 'low'].includes(x.confidence as string) ? x.confidence as Confidence : 'low';
    return { name_candidates: names.slice(0, 3), count, portion_bucket: bucket, has_broth: x.has_broth === true, confidence: conf };
  });
  return { is_food: true, items };
}

function stripFence(s: string): string {
  return s.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
}

export function toBase64(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}
