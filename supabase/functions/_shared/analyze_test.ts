import { assertEquals, assertRejects, assertThrows } from '@std/assert';
import { analyzeMeal, type AnalyzeDeps, type FoodMatch } from './analyze.ts';
import { MOCK_LUNCH, MockAdapter } from './ai/mock.ts';
import { MEAL_PROMPT, MEAL_SCHEMA, parseMealAnalysis, SchemaError } from './ai/types.ts';
import { selectAdapter } from './ai/select.ts';
import { ClaudeAdapter } from './ai/claude.ts';
import { GeminiAdapter } from './ai/gemini.ts';

// 시드 음식 DB와 같은 값(1인분 kcal)
const DB: Record<string, [string, number]> = {
  흰쌀밥: ['D000001', 310], 김치찌개: ['D000010', 260], 계란말이: ['D000020', 90], 멸치볶음: ['D000030', 20], 배추김치: ['D000040', 10], 김: ['D000050', 70],
  곰탕: ['D000060', 330],
};
const mapFood = (cands: string[]): Promise<FoodMatch> => {
  const hit = cands.find((c) => DB[c]);
  if (!hit) return Promise.resolve({ match: 'none', food_code: null, kcal: null, score: 0.1, chips: [] });
  const [code, kcal] = DB[hit];
  return Promise.resolve({ match: 'auto', food_code: code, kcal, score: 0.9, chips: [{ food_code: code, name: hit, kcal, score: 0.9 }] });
};

function deps(adapter: MockAdapter, saved: unknown[] = [], notified: string[] = []): AnalyzeDeps {
  return {
    adapter,
    loadImage: () => Promise.resolve({ bytes: new Uint8Array([1, 2, 3]), mimeType: 'image/jpeg' }),
    mapFood,
    saveDraft: (_id, r) => { saved.push(r); return Promise.resolve(); },
    notify: (_id, k) => { notified.push(k); return Promise.resolve(); },
    timeoutMs: 50,
  };
}

Deno.test('P7 점심 초안: 6항목 합계 850 (김 포함)', async () => {
  const saved: unknown[] = [], notified: string[] = [];
  const out = await analyzeMeal('m1', deps(new MockAdapter(), saved, notified));
  assertEquals(out.status, 'draft');
  if (out.status === 'draft') {
    assertEquals(out.ai_kcal, 850);
    assertEquals(out.items.length, 6);
    assertEquals(out.items.find((i) => i.chosen_name === '계란말이')?.ai_kcal, 180);
    assertEquals(out.items.find((i) => i.chosen_name === '김치찌개')?.has_broth, true);
    const rice = out.items[0];
    assertEquals(rice.candidates[0], '흰쌀밥'); // 선택 이름이 첫 칩
    assertEquals(rice.candidate_kcal.length, rice.candidates.length);
  }
  assertEquals(notified, ['done']);
});

Deno.test('재시도 1회: 첫 호출 실패 → 두 번째 성공', async () => {
  const a = new MockAdapter(MOCK_LUNCH, 1);
  const out = await analyzeMeal('m1', deps(a));
  assertEquals(out.status, 'draft');
  assertEquals(a.calls, 2);
});

Deno.test('타임아웃·오류 2회 → failed + 실패 알림', async () => {
  const notified: string[] = [];
  const out = await analyzeMeal('m1', deps(new MockAdapter(MOCK_LUNCH, 0, 200), [], notified));
  assertEquals(out, { status: 'failed', reason: 'timeout_or_error', attempts: 2 });
  assertEquals(notified, ['failed']);
});

Deno.test('is_food=false → failed(not_food) → P6 검색 폴백', async () => {
  const out = await analyzeMeal('m1', deps(new MockAdapter({ is_food: false, items: [] })));
  assertEquals(out.status === 'failed' && out.reason, 'not_food');
});

Deno.test('분량 구간·개수·미매칭 임시값', async () => {
  const out = await analyzeMeal('m1', deps(new MockAdapter({
    is_food: true,
    items: [
      { name_candidates: ['흰쌀밥'], count: 1, portion_bucket: 'large', has_broth: false, confidence: 'high' },
      { name_candidates: ['정체불명 요리'], count: 1, portion_bucket: 'one', has_broth: false, confidence: 'low' },
    ],
  })));
  if (out.status !== 'draft') throw new Error('expected draft');
  assertEquals(out.items[0].ai_kcal, 465); // 곱빼기 ×1.5
  assertEquals(out.items[1].needs_check, true);
  assertEquals(out.items[1].food_code, null);
});

Deno.test('스키마: kcal 숫자 출력은 거부, 8항목 초과는 자름, 코드펜스 허용', () => {
  assertThrows(() => parseMealAnalysis({ is_food: true, items: [{ name_candidates: ['밥 300kcal'], count: 1, portion_bucket: 'one', has_broth: false, confidence: 'high' }] }), SchemaError);
  assertThrows(() => parseMealAnalysis({ items: [] }), SchemaError);
  const many = { is_food: true, items: Array.from({ length: 10 }, () => MOCK_LUNCH.items[0]) };
  assertEquals(parseMealAnalysis(many).items.length, 8);
  assertEquals(parseMealAnalysis('```json\n{"is_food":false,"items":[]}\n```').is_food, false);
});

Deno.test('어댑터 선택: 키 없으면 mock, 키 있으면 해당 엔진', () => {
  assertEquals(selectAdapter(() => undefined).engine, 'mock');
  assertEquals(selectAdapter((k) => ({ GEMINI_API_KEY: 'x' } as Record<string, string>)[k]).engine, 'gemini');
  assertEquals(selectAdapter((k) => ({ AI_ENGINE: 'claude', ANTHROPIC_API_KEY: 'x' } as Record<string, string>)[k]).engine, 'claude');
});

Deno.test('Claude 어댑터: tool_use 입력을 그대로 반환(요청 형식 확인)', async () => {
  let sent: Record<string, unknown> = {};
  const fake: typeof fetch = (_u, init) => {
    sent = JSON.parse(String(init?.body));
    return Promise.resolve(new Response(JSON.stringify({ content: [{ type: 'tool_use', name: 'report_meal', input: MOCK_LUNCH }] })));
  };
  const a = new ClaudeAdapter({ apiKey: 'k', fetchImpl: fake });
  const raw = await a.analyze({ bytes: new Uint8Array([1]), mimeType: 'image/jpeg' }, { signal: new AbortController().signal });
  assertEquals(parseMealAnalysis(raw).items.length, 6);
  assertEquals((sent.tool_choice as { name: string }).name, 'report_meal');
});

Deno.test('Gemini 어댑터: responseSchema 요청·텍스트 JSON 파싱', async () => {
  let url = '';
  const fake: typeof fetch = (u, init) => {
    url = String(u);
    const b = JSON.parse(String(init?.body));
    assertEquals(b.generationConfig.responseMimeType, 'application/json');
    return Promise.resolve(new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(MOCK_LUNCH) }] } }] })));
  };
  const a = new GeminiAdapter({ vertex: { project: 'p', location: 'asia-northeast3', accessToken: 't' }, fetchImpl: fake });
  const raw = await a.analyze({ bytes: new Uint8Array([1]), mimeType: 'image/jpeg' }, { signal: new AbortController().signal });
  assertEquals(parseMealAnalysis(raw).items.length, 6);
  assertEquals(url.startsWith('https://asia-northeast3-aiplatform.googleapis.com/'), true);
  await assertRejects(() => new GeminiAdapter({ apiKey: 'k', fetchImpl: () => Promise.resolve(new Response('', { status: 503 })) })
    .analyze({ bytes: new Uint8Array([1]), mimeType: 'image/jpeg' }, { signal: new AbortController().signal }));
});

Deno.test('Gemini 어댑터: 기본 모델은 새 키로도 쓸 수 있는 gemini-3.5-flash-lite, GEMINI_MODEL 로 바꿀 수 있다', () => {
  assertEquals(
    new GeminiAdapter({ apiKey: 'k' }).url(),
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent',
  );
  assertEquals(new GeminiAdapter({ apiKey: 'k', model: 'gemini-3.8-flash' }).url().includes('/models/gemini-3.8-flash:'), true);
});

Deno.test('AI 인분 예측(servings, 0.1 단위): 배수·ai_kcal 에 쓰고, 범위 밖은 0.1~3.0 으로, 없으면 분량 구간으로', async () => {
  const out = await analyzeMeal('m1', deps(new MockAdapter({
    is_food: true,
    items: [
      { name_candidates: ['흰쌀밥'], count: 1, servings: 1.2, has_broth: false, confidence: 'high' },
      { name_candidates: ['김치찌개'], count: 1, servings: 0.04, has_broth: true, confidence: 'high' },
      { name_candidates: ['곰탕'], count: 1, servings: 7, has_broth: true, confidence: 'high' },
      { name_candidates: ['계란말이'], count: 1, servings: 1.26, has_broth: false, confidence: 'high' },
      { name_candidates: ['김'], count: 1, portion_bucket: 'large', has_broth: false, confidence: 'high' },
    ],
  })));
  if (out.status !== 'draft') throw new Error('expected draft');
  assertEquals(out.items.map((i) => i.portion_multiplier), [1.2, 0.1, 3, 1.3, 1.5]);
  assertEquals(out.items[0].ai_kcal, 372); // 310 × 1.2
  assertEquals(out.items.map((i) => i.portion_bucket), ['one', 'half', 'large', 'large', 'large']);
});

Deno.test('스키마·프롬프트: servings 를 요구한다', () => {
  const item = MEAL_SCHEMA.properties.items.items;
  assertEquals((item.required as readonly string[]).includes('servings'), true);
  assertEquals(MEAL_PROMPT.includes('servings'), true);
});

// 가공식품(D63): 포장 상품은 상품 행(1개 kcal)으로, 일반 음식 매칭에는 상품이 섞이지 않는다
const PRODUCTS: Record<string, [string, number]> = { 칙촉: ['P101-103000100-5334', 150.3], '롯데 칙촉': ['P101-103000100-5334', 150.3] };
function productDeps(adapter: MockAdapter, calls: [string[], boolean][]): AnalyzeDeps {
  return {
    ...deps(adapter),
    mapFood: (cands: string[], packaged = false): Promise<FoodMatch> => {
      calls.push([cands, packaged]);
      const hit = packaged ? cands.find((c) => PRODUCTS[c]) : undefined;
      if (!hit) return mapFood(cands);
      const [code, kcal] = PRODUCTS[hit];
      return Promise.resolve({ match: 'auto', food_code: code, kcal, score: 1, chips: [{ food_code: code, name: '칙촉', kcal, score: 1 }] });
    },
  };
}

Deno.test('포장 상품: 칙촉 2개 → 상품 행, ai_kcal = 1개 kcal × 개수(servings)', async () => {
  const calls: [string[], boolean][] = [];
  const out = await analyzeMeal('m1', productDeps(new MockAdapter({
    is_food: true,
    items: [{ name_candidates: ['롯데 칙촉', '칙촉', '초코칩쿠키'], count: 1, servings: 2, has_broth: false, confidence: 'high', packaged: true }],
  }), calls));
  if (out.status !== 'draft') throw new Error('expected draft');
  const it = out.items[0];
  assertEquals([it.food_code, it.chosen_name, it.serving_kcal, it.portion_multiplier, it.ai_kcal], ['P101-103000100-5334', '칙촉', 150.3, 2, 300.6]);
  assertEquals(calls.every(([, p]) => p), true, '포장 상품 항목은 모든 매핑을 상품 먼저로');
});

Deno.test('포장 상품이 아니면 상품으로 매핑하지 않는다(packaged 기본 false)', async () => {
  const calls: [string[], boolean][] = [];
  const out = await analyzeMeal('m1', productDeps(new MockAdapter({
    is_food: true,
    items: [{ name_candidates: ['칙촉'], count: 1, servings: 1, has_broth: false, confidence: 'high' }],
  }), calls));
  if (out.status !== 'draft') throw new Error('expected draft');
  assertEquals(out.items[0].food_code, null);
  assertEquals(calls.some(([, p]) => p), false);
});

Deno.test('스키마·프롬프트: 항목별 packaged(포장 상품), 없으면 false', () => {
  const item = MEAL_SCHEMA.properties.items.items;
  assertEquals(item.properties.packaged, { type: 'boolean' });
  assertEquals((item.required as readonly string[]).includes('packaged'), true);
  assertEquals(MEAL_PROMPT.includes('packaged'), true);
  const base = { name_candidates: ['칙촉'], count: 1, servings: 1, has_broth: false, confidence: 'high' };
  const parsed = parseMealAnalysis({ is_food: true, items: [{ ...base, packaged: true }, base, { ...base, packaged: 'yes' }] });
  assertEquals(parsed.items.map((i) => i.packaged), [true, false, false]);
});

Deno.test('스키마: 포장 상품 이름의 용량·중량은 떼어 내고, kcal 숫자는 거부', () => {
  const item = (names: string[]) => ({ is_food: true, items: [{ name_candidates: names, count: 1, servings: 1, has_broth: false, confidence: 'high' }] });
  assertEquals(parseMealAnalysis(item(['새우깡 90g', '농심 새우깡(90g)'])).items[0].name_candidates, ['새우깡', '농심 새우깡']);
  assertEquals(parseMealAnalysis(item(['콜라 1.5L'])).items[0].name_candidates, ['콜라']);
  assertEquals(parseMealAnalysis(item(['새우깡 90g', '새우깡'])).items[0].name_candidates, ['새우깡'], '떼고 같아진 이름은 하나로');
  assertEquals(parseMealAnalysis(item(['1등급 한우', '2인분 피자'])).items[0].name_candidates, ['1등급 한우', '2인분 피자'], '단위 아닌 숫자는 그대로');
  assertEquals(parseMealAnalysis(item(['3겹살 구이', '홍삼 진액 10ml 스틱'])).items[0].name_candidates, ['3겹살 구이', '홍삼 진액 스틱']);
  assertThrows(() => parseMealAnalysis(item(['90g'])), SchemaError);
  assertThrows(() => parseMealAnalysis(item(['밥 300kcal'])), SchemaError);
  assertThrows(() => parseMealAnalysis(item(['밥 300 칼로리'])), SchemaError);
});

// '몇 개입'(D64): 끼니 주인이 개입 수를 넣은 상품이면 1개 kcal(piece_kcal) × servings, 없으면 그대로
const CHIC = 'P101-103000100-5334';
const chicItem = (servings: number, packaged = true) => ({
  is_food: true,
  items: [
    { name_candidates: ['롯데 칙촉', '칙촉'], count: 1, servings, has_broth: false, confidence: 'high', packaged },
    { name_candidates: ['흰쌀밥'], count: 1, servings: 1, has_broth: false, confidence: 'high', packaged: false },
  ],
});

Deno.test('개입 수가 있는 포장 상품: 1개 kcal × servings', async () => {
  const asked: string[][] = [];
  const d: AnalyzeDeps = {
    ...productDeps(new MockAdapter(chicItem(3)), []),
    productPieces: (codes) => {
      asked.push(codes);
      return Promise.resolve({ [CHIC]: { pieces: 24, piece_g: 7.5, piece_kcal: 37.6 } });
    },
  };
  const out = await analyzeMeal('m1', d);
  if (out.status !== 'draft') throw new Error('expected draft');
  const [chic, rice] = out.items;
  assertEquals([chic.food_code, chic.serving_kcal, chic.portion_multiplier, chic.ai_kcal], [CHIC, 37.6, 3, 112.8]);
  assertEquals(chic.candidate_kcal, [37.6], '후보 칩 kcal 도 1개 단위');
  assertEquals([rice.food_code, rice.serving_kcal, rice.ai_kcal], ['D000001', 310, 310], '음식 항목은 그대로');
  assertEquals(out.ai_kcal, 422.8);
  assertEquals(asked, [[CHIC]], '포장 상품 항목의 코드만 한 번에 묻는다');
});

Deno.test('개입 수가 없으면 1회분 그대로, 포장 상품이 없으면 묻지 않는다', async () => {
  let calls = 0;
  const pieces = () => { calls++; return Promise.resolve({}); };
  const out = await analyzeMeal('m1', { ...productDeps(new MockAdapter(chicItem(2)), []), productPieces: pieces });
  if (out.status !== 'draft') throw new Error('expected draft');
  assertEquals([out.items[0].serving_kcal, out.items[0].ai_kcal, out.ai_kcal], [150.3, 300.6, 610.6]);
  assertEquals(calls, 1);
  const dish = await analyzeMeal('m1', { ...productDeps(new MockAdapter(chicItem(2, false)), []), productPieces: pieces });
  if (dish.status !== 'draft') throw new Error('expected draft');
  assertEquals(dish.items[0].food_code, null, '포장 상품이 아니면 상품 매칭 없음');
  assertEquals(calls, 1, '포장 상품 코드가 없으면 조회하지 않음');
});

Deno.test('프롬프트: 포장 상품 이름은 포장에 적힌 맛·종류까지(홈런볼 초코, 칙촉 오리지널)', () => {
  assertEquals(MEAL_PROMPT.includes('맛·종류'), true);
  assertEquals(MEAL_PROMPT.includes('"홈런볼 초코"'), true);
  assertEquals(MEAL_PROMPT.includes('"칙촉 오리지널"'), true);
});

Deno.test('프롬프트: 포장 상품은 count = 따로 보이는 봉지·포장 수, servings = 한 포장당 양(보통 1.0)', () => {
  assertEquals(MEAL_PROMPT.includes('포장 상품의 count 는 따로 보이는 봉지·포장 수'), true);
  assertEquals(MEAL_PROMPT.includes('servings 는 그 상품 단위 대비 한 포장당 양(보통 1.0'), true);
  assertEquals(MEAL_PROMPT.includes('count 는 1 로 두고'), false);
});

Deno.test('개입 수 조회가 안 되면 1회분 초안 그대로(분석은 계속)', async () => {
  const d: AnalyzeDeps = {
    ...productDeps(new MockAdapter(chicItem(2)), []),
    productPieces: () => Promise.reject(new Error('db down')),
  };
  const out = await analyzeMeal('m1', d);
  if (out.status !== 'draft') throw new Error('expected draft');
  assertEquals([out.items[0].serving_kcal, out.items[0].ai_kcal, out.items[0].candidate_kcal], [150.3, 300.6, [150.3]]);
});

Deno.test('개입 수는 고른 후보에만: 다른 상품 후보의 칩 kcal 은 1회분 그대로', async () => {
  const OTHER = 'P900-000000000-0002';
  const d: AnalyzeDeps = {
    ...deps(new MockAdapter({
      is_food: true,
      items: [{ name_candidates: ['칙촉', '칙촉 브라우니'], count: 1, servings: 1, has_broth: false, confidence: 'high', packaged: true }],
    })),
    mapFood: (cands: string[]): Promise<FoodMatch> => {
      const [code, kcal, name] = cands[0] === '칙촉 브라우니' ? [OTHER, 190, '칙촉 브라우니'] : [CHIC, 150.3, '칙촉'];
      return Promise.resolve({ match: 'auto', food_code: code, kcal, score: 1, chips: [{ food_code: code, name, kcal, score: 1 }] });
    },
    productPieces: () => Promise.resolve({ [CHIC]: { pieces: 24, piece_g: 7.5, piece_kcal: 37.6 }, [OTHER]: { pieces: 10, piece_g: 4, piece_kcal: 19 } }),
  };
  const out = await analyzeMeal('m1', d);
  if (out.status !== 'draft') throw new Error('expected draft');
  assertEquals(out.items[0].candidate_food_codes, [CHIC, OTHER]);
  assertEquals([out.items[0].serving_kcal, out.items[0].candidate_kcal], [37.6, [37.6, 190]]);
});

// 낱개 포장 한 개(D67): 포장 상품이 큰 상자에서 꺼낸 낱개 봉지 하나로 보이면 single_piece=true → 초안 항목에 저장(앱이 '몇 개입' 배너)
Deno.test('스키마·프롬프트: 항목별 single_piece(낱개 포장 한 개), 없으면 false, 포장 상품만', () => {
  const item = MEAL_SCHEMA.properties.items.items;
  assertEquals(item.properties.single_piece, { type: 'boolean' });
  assertEquals((item.required as readonly string[]).includes('single_piece'), true);
  assertEquals(MEAL_PROMPT.includes('single_piece'), true);
  assertEquals(MEAL_PROMPT.includes('낱개 포장'), true);
  const base = { name_candidates: ['칙촉'], count: 1, servings: 1, has_broth: false, confidence: 'high', packaged: true };
  const parsed = parseMealAnalysis({
    is_food: true,
    items: [{ ...base, single_piece: true }, base, { ...base, single_piece: 'yes' }, { ...base, packaged: false, single_piece: true }],
  });
  assertEquals(parsed.items.map((i) => i.single_piece), [true, false, false, false]);
});

Deno.test('낱개 포장 한 개로 본 포장 상품: 초안 항목에 single_piece 저장, 그 밖은 false', async () => {
  const saved: { items: { single_piece: boolean }[] }[] = [];
  const d: AnalyzeDeps = {
    ...productDeps(new MockAdapter({
      is_food: true,
      items: [
        { name_candidates: ['롯데 칙촉', '칙촉'], count: 1, servings: 1, has_broth: false, confidence: 'high', packaged: true, single_piece: true },
        { name_candidates: ['흰쌀밥'], count: 1, servings: 1, has_broth: false, confidence: 'high', packaged: false },
      ],
    }), []),
    saveDraft: (_id, r) => { saved.push(r); return Promise.resolve(); },
  };
  const out = await analyzeMeal('m1', d);
  if (out.status !== 'draft') throw new Error('expected draft');
  assertEquals(out.items.map((i) => i.single_piece), [true, false]);
  assertEquals(saved[0].items.map((i) => i.single_piece), [true, false]);
  assertEquals([out.items[0].serving_kcal, out.items[0].ai_kcal], [150.3, 150.3], 'kcal 은 그대로(1회분) — 앱이 묻는다');
});
