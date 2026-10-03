// Gemini 어댑터. Vertex AI(서울 리전 가용 시 우선) 또는 Generative Language API.
// 기본 모델 gemini-3.5-flash-lite: 2.5 모델은 예전에 2.5 를 쓰던 사용자에게만 열려 새 키로는 404 가 난다.
// GEMINI_MODEL 로 바꿀 수 있다(analyze-meal 은 1회 8초 제한이라 응답이 빠른 모델이어야 한다).
// 환경변수: GEMINI_API_KEY(Generative Language) 또는 VERTEX_PROJECT·VERTEX_LOCATION·VERTEX_ACCESS_TOKEN(Vertex AI).
import { MEAL_PROMPT, MEAL_SCHEMA, type MealImage, type MealVisionAdapter, toBase64 } from './types.ts';

export interface GeminiConfig {
  apiKey?: string;
  vertex?: { project: string; location: string; accessToken: string };
  model?: string;
  fetchImpl?: typeof fetch;
}

export class GeminiAdapter implements MealVisionAdapter {
  readonly engine = 'gemini' as const;
  constructor(private cfg: GeminiConfig) {
    if (!cfg.apiKey && !cfg.vertex) throw new Error('Gemini: GEMINI_API_KEY 또는 Vertex 설정 필요');
  }

  url(): string {
    const model = this.cfg.model ?? 'gemini-3.5-flash-lite';
    if (this.cfg.vertex) {
      const { project, location } = this.cfg.vertex;
      return `https://${location}-aiplatform.googleapis.com/v1/projects/${project}/locations/${location}/publishers/google/models/${model}:generateContent`;
    }
    return `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
  }

  async analyze(image: MealImage, { signal }: { signal: AbortSignal }): Promise<unknown> {
    const body = {
      contents: [{ role: 'user', parts: [{ inlineData: { mimeType: image.mimeType, data: toBase64(image.bytes) } }, { text: MEAL_PROMPT }] }],
      generationConfig: { responseMimeType: 'application/json', responseSchema: MEAL_SCHEMA, temperature: 0 },
    };
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (this.cfg.vertex) headers.authorization = `Bearer ${this.cfg.vertex.accessToken}`;
    else headers['x-goog-api-key'] = this.cfg.apiKey!;
    const res = await (this.cfg.fetchImpl ?? fetch)(this.url(), { method: 'POST', headers, body: JSON.stringify(body), signal });
    if (!res.ok) throw new Error(`gemini ${res.status}`);
    const j = await res.json();
    const text = j?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (typeof text !== 'string') throw new Error('gemini: empty response');
    return text;
  }
}
