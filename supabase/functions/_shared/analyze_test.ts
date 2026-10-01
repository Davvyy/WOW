import { assertEquals, assertRejects, assertThrows } from '@std/assert';
import { analyzeMeal, type AnalyzeDeps, type FoodMatch } from './analyze.ts';
import { MOCK_LUNCH, MockAdapter } from './ai/mock.ts';
import { parseMealAnalysis, SchemaError } from './ai/types.ts';
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
