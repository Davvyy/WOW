// Claude Haiku 4.5 스왑 어댑터 (Anthropic Messages API). 도구 호출을 강제해 JSON 스키마를 지키게 한다.
// 환경변수: ANTHROPIC_API_KEY
import { MEAL_PROMPT, MEAL_SCHEMA, type MealImage, type MealVisionAdapter, toBase64 } from './types.ts';

export interface ClaudeConfig {
  apiKey: string;
  model?: string;
  fetchImpl?: typeof fetch;
}

export class ClaudeAdapter implements MealVisionAdapter {
  readonly engine = 'claude' as const;
  constructor(private cfg: ClaudeConfig) {
    if (!cfg.apiKey) throw new Error('Claude: ANTHROPIC_API_KEY 필요');
  }

  async analyze(image: MealImage, { signal }: { signal: AbortSignal }): Promise<unknown> {
    const body = {
      model: this.cfg.model ?? 'claude-haiku-4-5',
      max_tokens: 1024,
      tools: [{ name: 'report_meal', description: '사진 속 음식 식별 결과', input_schema: MEAL_SCHEMA }],
      tool_choice: { type: 'tool', name: 'report_meal' },
      messages: [{
        role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: image.mimeType, data: toBase64(image.bytes) } },
          { type: 'text', text: MEAL_PROMPT },
        ],
      }],
    };
    const res = await (this.cfg.fetchImpl ?? fetch)('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': this.cfg.apiKey, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify(body),
      signal,
    });
    if (!res.ok) throw new Error(`claude ${res.status}`);
    const j = await res.json();
    const tool = (j?.content ?? []).find((c: { type: string }) => c.type === 'tool_use');
    if (!tool) throw new Error('claude: no tool_use block');
    return tool.input;
  }
}
