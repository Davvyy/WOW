// @vitest-environment jsdom
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import App from './App';
import { getApi } from './data';

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let root: Root | null = null;
let host: HTMLElement;

async function visit(path: string): Promise<string> {
  window.history.pushState({}, '', path);
  host = document.createElement('div');
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => { root!.render(<App />); });
  for (let i = 0; i < 8; i++) await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
  return host.textContent ?? '';
}

async function click(el: Element | null | undefined) {
  if (!el) throw new Error('요소를 찾지 못했어요');
  await act(async () => { (el as HTMLElement).click(); });
  for (let i = 0; i < 5; i++) await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
}

/** 제어 입력(React)에 값 넣기 */
async function type(el: Element | null | undefined, value: string) {
  if (!el) throw new Error('입력을 찾지 못했어요');
  const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!;
  await act(async () => { set.call(el, value); el.dispatchEvent(new Event('input', { bubbles: true })); });
}

beforeAll(() => { getApi().mock?.setScenario('running'); });
afterEach(async () => { await act(async () => { root?.unmount(); }); host?.remove(); root = null; });

describe('콘솔 화면 스모크(모의 데이터)', () => {
  it('OP0 챌린지 목록', async () => {
    const t = await visit('/');
    expect(t).toContain('가을 걷기 챌린지');
    expect(t).toContain('참가 42/60');
    expect(t).toContain('미결 3건');
  });

  it('OP1 설정: 샘플 시뮬레이션 28.8 / 72.1 / 0.0', async () => {
    const t = await visit('/c/ch-autumn/settings');
    expect(t).toContain('약 28.8');
    expect(t).toContain('약 72.1');
    expect(t).toContain('약 0.0');
    expect(t).toContain('K7Q2MD');
    expect(t).toContain('P11 미리보기');
  });

  it('OP2 참가자: 표·필터·건강 알림', async () => {
    const t = await visit('/c/ch-autumn/participants?filter=unsynced');
    expect(t).toContain('미동기화 3명');
    expect(t).toContain('라떼한잔');
    expect(t).toContain('운영자만 열람 · CSV 미포함');
  });

  it('OP3 검토 큐: 지수 무효 미리보기와 알림 문구, 확정 후 미결 감소', async () => {
    const t = await visit('/c/ch-autumn/reviews?review=rv-0415');
    expect(t).toContain('R-0415');
    await click(host.querySelector('input[name="verdict"][value="void"]'));
    const t2 = host.textContent ?? '';
    expect(t2).toContain('S 41.2 → 12.7');
    expect(t2).toContain('같은 사진이 두 번 이상 사용됐어요. 대체값 743으로 다시 계산했어요. 10.12 41.2→12.7점 · 누적 −28.5');
    await click(host.querySelector('#confirmBtn'));
    expect(host.textContent).toContain('판정을 저장했어요');
    expect(await getApi().openReviewCount('ch-autumn')).toBe(2);
  });
});

describe('OP4', () => {
  it('미결이 있으면 차단 배너, 0건이면 확정 버튼', async () => {
    getApi().mock!.setScenario('closing');
    const t = await visit('/c/ch-autumn/results');
    expect(t).toContain('미결 3건이 있어 최종 확정을 할 수 없어요');
    const btn = Array.from(host.querySelectorAll('button')).find((b) => b.textContent?.includes('최종 확정'));
    expect(btn?.hasAttribute('disabled')).toBe(true);
    await act(async () => { root?.unmount(); }); host.remove();
    getApi().mock!.setScenario('closing-clear');
    const t2 = await visit('/c/ch-autumn/results');
    expect(t2).toContain('미결 0건');
    const ok = Array.from(host.querySelectorAll('button')).find((b) => b.textContent?.includes('최종 확정'));
    expect(ok?.hasAttribute('disabled')).toBe(false);
  });
  it('OP0 새 챌린지: 입력 검사 → 만들면 초안으로 OP1 설정에 들어가고 목록에도 보인다', async () => {
    await visit('/');
    const btn = Array.from(host.querySelectorAll('button')).find((b) => b.textContent?.includes('새 챌린지'));
    expect(btn?.hasAttribute('disabled')).toBe(false);
    await click(btn);
    expect(host.textContent).toContain('새 챌린지 만들기');
    await type(host.querySelector('#n-name'), '봄 걷기 챌린지');
    await type(host.querySelector('#n-cap'), '10');
    await click(Array.from(host.querySelectorAll('button')).find((b) => b.textContent?.includes('만들기')));
    expect(host.textContent).toContain('정원은 30~100명으로 정해 주세요');
    await type(host.querySelector('#n-cap'), '40');
    await click(Array.from(host.querySelectorAll('button')).find((b) => b.textContent?.includes('만들기')));
    expect(window.location.pathname).toMatch(/^\/c\/ch-new-\d+\/settings$/);
    expect(host.textContent).toContain('봄 걷기 챌린지');
    const list = await visit('/');
    expect(list).toContain('봄 걷기 챌린지');
    expect(list).toContain('참가 0/40');
  });
});
