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

/** 상품 1개(낱개) 단위: 포장 크기 ÷ 개입 수, kcal 은 소수 1자리(서버 product_piece_kcal) */
export interface ProductPieces {
  pieces: number;
  piece_g: number;
  piece_kcal: number;
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
  single_piece: boolean; // 포장 상품이 낱개 포장 하나로 보임(D67) → meal_items.ai_single_piece
}

export interface AnalyzeDeps {
  adapter: MealVisionAdapter;
  loadImage(mealId: string): Promise<MealImage>;
  /** 후보 이름 → 식약처 DB. packaged(포장 상품)면 상품 행 먼저, 아니면 음식 행만(D63) */
  mapFood(candidates: string[], packaged?: boolean): Promise<FoodMatch>;
  /** 끼니 주인이 '몇 개입'을 넣은 상품 코드 → 1개 양·kcal(D64). 없으면 1회분 그대로 */
  productPieces?(codes: string[]): Promise<Record<string, ProductPieces>>;
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

export async function buildDraftItems(analysis: MealAnalysis, deps: Pick<AnalyzeDeps, 'mapFood' | 'unmatchedKcal' | 'productPieces'>): Promise<DraftItem[]> {
  const out: DraftItem[] = [];
  for (const it of analysis.items) {
    const m = await deps.mapFood(it.name_candidates as string[], it.packaged);
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
    const mult = it.servings; // AI 가 사진으로 본 인분(0.1 단위, 포장 상품은 한 포장당 양) — P7 먹은 양 기본값
    // 후보 칩: 선택 이름을 맨 앞에, 나머지 LLM 후보는 각자 DB 매칭 kcal(실패 시 선택 항목 값)
    const candidates = [chosen];
    const candidate_kcal = [serving];
    const candidate_food_codes: (string | null)[] = [food_code];
    for (const name of it.name_candidates as string[]) {
      if (candidates.includes(name) || candidates.length >= 3) continue;
      const cm = await deps.mapFood([name], it.packaged);
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
      single_piece: it.single_piece,
    });
  }
  await applyProductPieces(analysis, out, deps);
  return out;
}

/** 포장 상품 항목의 고른 후보(후보 0)가 개입 수를 넣은 상품이면 그 kcal 을 1개 kcal 로. 다른 후보·음식 항목은 그대로.
 * 앱은 고른 후보만 낱개 단위로 열기 때문에 다른 후보 칩은 1회분 kcal 로 둔다. 조회가 안 되면 1회분 초안 그대로(분석은 계속). */
async function applyProductPieces(analysis: MealAnalysis, items: DraftItem[], deps: Pick<AnalyzeDeps, 'productPieces'>) {
  if (!deps.productPieces) return;
  const chosen = (d: DraftItem, i: number) => (analysis.items[i].packaged ? d.candidate_food_codes[0] : null);
  const codes = [...new Set(items.map(chosen).filter((c): c is string => !!c))];
  if (codes.length === 0) return;
  let pieces: Record<string, ProductPieces>;
  try {
    pieces = await deps.productPieces(codes);
  } catch (e) {
    console.error('product_pieces_for', e);
    return;
  }
  items.forEach((d, i) => {
    const c = chosen(d, i);
    const p = c ? pieces[c] : undefined;
    if (!p) return;
    d.candidate_kcal[0] = p.piece_kcal;
    d.serving_kcal = p.piece_kcal;
    d.ai_kcal = round1(p.piece_kcal * d.portion_multiplier * d.count);
  });
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
