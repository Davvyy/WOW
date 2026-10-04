// 식사 분석 파이프라인(05 §6): 사진 → LLM JSON(타임아웃 8초·재시도 1회) → 스키마 검증 → 식약처 DB 매핑 → 초안 저장 → N-04.
// I/O는 모두 deps 로 주입한다(단위 테스트는 모의 deps, 운영은 analyze-meal/index.ts 의 Supabase 구현).
import { type MealAnalysis, type MealImage, type MealVisionAdapter, parseMealAnalysis, type PortionBucket } from './ai/types.ts';

export { PORTION_MULTIPLIER } from './ai/types.ts';

export interface FoodMatch {
  match: 'auto' | 'chips' | 'none'; // ≥0.45 자동 / 0.25~0.45 후보 칩 / <0.25 미매칭 (04 §4.2)
  food_code: string | null;
  kcal: number | null; // 1인분 kcal
  score: number | null;
  chips: { food_code: string; name: string; kcal: number; score: number }[];
}

export interface DraftItem {
  name_candidates: string[];
  chosen_name: string;
  food_code: string | null;
  count: number;
  portion_bucket: PortionBucket;
  portion_multiplier: number;
  has_broth: boolean;
  confidence: 'high' | 'mid' | 'low';
  match_score: number | null;
  needs_check: boolean;
  serving_kcal: number;
  ai_kcal: number;
  candidates: string[]; // [선택된 이름, …나머지 후보] — P7 후보 칩
  candidate_kcal: number[]; // 후보별 1인분 kcal(매칭 실패 후보는 선택 항목 값)
  candidate_food_codes: (string | null)[];
}

export interface AnalyzeDeps {
  adapter: MealVisionAdapter;
  loadImage(mealId: string): Promise<MealImage>;
  mapFood(candidates: string[]): Promise<FoodMatch>;
  saveDraft(mealId: string, r: { status: 'draft' | 'failed'; engine: string; ai_kcal: number | null; items: DraftItem[]; reason?: string }): Promise<void>;
  notify(mealId: string, kind: 'done' | 'failed'): Promise<void>;
  unmatchedKcal?: number; // 미매칭 임시값(분류 중앙값 [제안]), 기본 200
  timeoutMs?: number; // 기본 8000
  attempts?: number; // 기본 2(재시도 1회)
}

export type AnalyzeOutcome =
  | { status: 'draft'; ai_kcal: number; items: DraftItem[]; attempts: number }
  | { status: 'failed'; reason: 'not_food' | 'timeout_or_error' | 'schema'; attempts: number };

const round1 = (x: number) => Math.floor(x * 10 + 0.5) / 10;

export async function callWithRetry(adapter: MealVisionAdapter, image: MealImage, timeoutMs: number, attempts: number) {
  let lastErr: unknown;
  let schemaErr = false;
  for (let i = 1; i <= attempts; i++) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), timeoutMs);
    try {
      const raw = await adapter.analyze(image, { signal: ctl.signal });
      try {
        return { analysis: parseMealAnalysis(raw), attempts: i };
      } catch (e) {
        schemaErr = true;
        lastErr = e;
      }
    } catch (e) {
      schemaErr = false;
      lastErr = e;
    } finally {
      clearTimeout(timer);
    }
  }
  return { error: lastErr, schema: schemaErr, attempts };
}

export async function buildDraftItems(analysis: MealAnalysis, deps: Pick<AnalyzeDeps, 'mapFood' | 'unmatchedKcal'>): Promise<DraftItem[]> {
  const out: DraftItem[] = [];
  for (const it of analysis.items) {
    const m = await deps.mapFood(it.name_candidates as string[]);
    let food_code: string | null = null;
    let serving: number;
    let chosen = it.name_candidates[0];
    let needsCheck = it.confidence !== 'high';
    if (m.match === 'auto' && m.kcal != null) {
      food_code = m.food_code;
      serving = m.kcal;
      const chip = m.chips.find((c) => c.food_code === m.food_code);
      if (chip) chosen = chip.name;
    } else if (m.match === 'chips' && m.chips.length > 0) {
      food_code = m.chips[0].food_code; // 후보 칩 1순위를 임시 선택, 확인 필요
      serving = m.chips[0].kcal;
      chosen = m.chips[0].name;
      needsCheck = true;
    } else {
      serving = deps.unmatchedKcal ?? 200; // 미매칭 → 임시값 + 확인 필요
      needsCheck = true;
    }
    const mult = it.servings; // AI 가 사진으로 본 인분(0.1 단위) — P7 먹은 양 기본값
    // 후보 칩: 선택 이름을 맨 앞에, 나머지 LLM 후보는 각자 DB 매칭 kcal(실패 시 선택 항목 값)
    const candidates = [chosen];
    const candidate_kcal = [serving];
    const candidate_food_codes: (string | null)[] = [food_code];
    for (const name of it.name_candidates as string[]) {
      if (candidates.includes(name) || candidates.length >= 3) continue;
      const cm = await deps.mapFood([name]);
      const hit = cm.match === 'auto' ? { code: cm.food_code, kcal: cm.kcal } : cm.chips[0] ? { code: cm.chips[0].food_code, kcal: cm.chips[0].kcal } : null;
      if (hit && hit.code && candidate_food_codes.includes(hit.code)) continue;
      candidates.push(name);
      candidate_kcal.push(hit?.kcal ?? serving);
      candidate_food_codes.push(hit?.code ?? null);
    }
    out.push({
      candidates,
      candidate_kcal,
      candidate_food_codes,
      name_candidates: it.name_candidates as string[],
      chosen_name: chosen,
      food_code,
      count: it.count,
      portion_bucket: it.portion_bucket,
      portion_multiplier: mult,
      has_broth: it.has_broth,
      confidence: it.confidence,
      match_score: m.score,
      needs_check: needsCheck,
      serving_kcal: serving,
      ai_kcal: round1(serving * mult * it.count),
    });
  }
  return out;
}

export async function analyzeMeal(mealId: string, deps: AnalyzeDeps): Promise<AnalyzeOutcome> {
  const image = await deps.loadImage(mealId);
  const r = await callWithRetry(deps.adapter, image, deps.timeoutMs ?? 8000, deps.attempts ?? 2);
  if ('error' in r) {
    const reason = r.schema ? 'schema' : 'timeout_or_error';
    await deps.saveDraft(mealId, { status: 'failed', engine: deps.adapter.engine, ai_kcal: null, items: [], reason });
    await deps.notify(mealId, 'failed');
    return { status: 'failed', reason, attempts: r.attempts };
  }
  if (!r.analysis.is_food || r.analysis.items.length === 0) {
    await deps.saveDraft(mealId, { status: 'failed', engine: deps.adapter.engine, ai_kcal: null, items: [], reason: 'not_food' });
    await deps.notify(mealId, 'failed');
    return { status: 'failed', reason: 'not_food', attempts: r.attempts };
  }
  const items = await buildDraftItems(r.analysis, deps);
  const ai_kcal = round1(items.reduce((a, x) => a + x.ai_kcal, 0));
  await deps.saveDraft(mealId, { status: 'draft', engine: deps.adapter.engine, ai_kcal, items });
  await deps.notify(mealId, 'done');
  return { status: 'draft', ai_kcal, items, attempts: r.attempts };
}
