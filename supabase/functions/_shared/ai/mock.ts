// 모의 어댑터: API 키 없이 로컬 개발·테스트. 프로토타입 P7 점심 초안(김치찌개 백반 6항목)을 돌려준다.
import type { MealImage, MealVisionAdapter } from './types.ts';

export const MOCK_LUNCH = {
  is_food: true,
  items: [
    { name_candidates: ['흰쌀밥', '현미밥', '잡곡밥'], count: 1, portion_bucket: 'one', has_broth: false, confidence: 'high' },
    { name_candidates: ['김치찌개', '부대찌개', '된장찌개'], count: 1, portion_bucket: 'one', has_broth: true, confidence: 'high' },
    { name_candidates: ['계란말이', '계란찜', '계란후라이'], count: 2, portion_bucket: 'one', has_broth: false, confidence: 'mid' },
    { name_candidates: ['멸치볶음', '진미채볶음', '건새우볶음'], count: 1, portion_bucket: 'one', has_broth: false, confidence: 'high' },
    { name_candidates: ['배추김치', '총각김치', '깍두기'], count: 1, portion_bucket: 'one', has_broth: false, confidence: 'high' },
    { name_candidates: ['김', '조미김', '김부각'], count: 1, portion_bucket: 'one', has_broth: false, confidence: 'high' },
  ],
};

export class MockAdapter implements MealVisionAdapter {
  readonly engine = 'mock' as const;
  calls = 0;
  constructor(private response: unknown = MOCK_LUNCH, private failTimes = 0, private delayMs = 0) {}
  async analyze(_image: MealImage, { signal }: { signal: AbortSignal }): Promise<unknown> {
    this.calls++;
    if (this.delayMs) {
      await new Promise<void>((resolve, reject) => {
        const t = setTimeout(resolve, this.delayMs);
        signal.addEventListener('abort', () => { clearTimeout(t); reject(new DOMException('aborted', 'AbortError')); });
      });
    }
    if (this.calls <= this.failTimes) throw new Error('mock 503');
    return structuredClone(this.response);
  }
}
