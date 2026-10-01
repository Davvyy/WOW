// 엔진 선택: AI_ENGINE=gemini|claude|mock (기본 gemini). 키가 없으면 mock 으로 내려간다(로컬).
// 1차 엔진 실패(타임아웃·5xx 2회)는 호출 측이 failed 로 처리하고, 스왑은 설정으로만 한다(미결 10-6).
import { ClaudeAdapter } from './claude.ts';
import { GeminiAdapter } from './gemini.ts';
import { MockAdapter } from './mock.ts';
import type { MealVisionAdapter } from './types.ts';

export function selectAdapter(env: (k: string) => string | undefined): MealVisionAdapter {
  const want = (env('AI_ENGINE') ?? 'gemini').toLowerCase();
  if (want === 'claude' && env('ANTHROPIC_API_KEY')) {
    return new ClaudeAdapter({ apiKey: env('ANTHROPIC_API_KEY')!, model: env('CLAUDE_MODEL') });
  }
  if (want === 'gemini') {
    if (env('VERTEX_PROJECT') && env('VERTEX_ACCESS_TOKEN')) {
      return new GeminiAdapter({
        vertex: { project: env('VERTEX_PROJECT')!, location: env('VERTEX_LOCATION') ?? 'asia-northeast3', accessToken: env('VERTEX_ACCESS_TOKEN')! },
        model: env('GEMINI_MODEL'),
      });
    }
    if (env('GEMINI_API_KEY')) return new GeminiAdapter({ apiKey: env('GEMINI_API_KEY'), model: env('GEMINI_MODEL') });
  }
  return new MockAdapter();
}
