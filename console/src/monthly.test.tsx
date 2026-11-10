// @vitest-environment jsdom
// 월간 챌린지는 정원·초대코드가 없다(서버 값 null): 콘솔이 "1/0"·끝이 빈 초대 링크로 보이면 안 된다.
// 첫 요청이 느리거나 오류가 나도 빈 화면으로 멈추지 않는다.
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, describe, expect, it } from 'vitest';
import App from './App';
import { ConsoleProvider } from './context';
import type { ConsoleApi } from './data/api';
import { challengeBasicsError, joinedLabel, snackRuleNote } from './lib/challengeForm';

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let root: Root | null = null;
let host: HTMLElement;

async function settle() {
  for (let i = 0; i < 8; i++) await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
}
async function mount(node: React.ReactNode) {
  host = document.createElement('div');
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => { root!.render(node); });
  await settle();
  return host;
}
async function visit(path: string) {
  window.history.pushState({}, '', path);
  return (await mount(<App />)).textContent ?? '';
}
afterEach(async () => { await act(async () => { root?.unmount(); }); host?.remove(); root = null; });

describe('월간 챌린지(정원·초대코드 없음)', () => {
  it('참가 인원 표기: 정원이 없으면 "N명", 있으면 "N/정원"', () => {
    expect(joinedLabel({ joined: 1, capacity: null })).toBe('1명');
    expect(joinedLabel({ joined: 42, capacity: 60 })).toBe('42/60');
  });

  it('OP0 목록에 /0 이 없다', async () => {
    const t = await visit('/');
    expect(t).toContain('11월 챌린지');
    expect(t).toContain('참가 3명');
    expect(t).not.toContain('3/0');
  });

  it('OP2 참가자 요약에 / 0 이 없다', async () => {
    const t = await visit('/c/ch-monthly/participants');
    expect(t).not.toMatch(/\/ ?0(?!\d)/);
  });

  it('OP1: 정원은 제한 없음, 초대 링크 대신 월간 안내', async () => {
    const t = await visit('/c/ch-monthly/settings');
    expect((host.querySelector('#f-cap') as HTMLInputElement).value).toBe('제한 없음');
    expect(t).toContain('월간 챌린지는 초대코드가 없어요');
    expect(t).not.toContain('초대 링크 복사');
    expect(t).not.toContain('정원 0명');
  });

  it('OP1 정원 칸: 단위 "명"을 붙이지 않고 읽기 전용으로 알린다', async () => {
    await visit('/c/ch-monthly/settings');
    const cap = host.querySelector('#f-cap') as HTMLInputElement;
    expect(cap.getAttribute('aria-readonly')).toBe('true');
    expect(cap.parentElement!.querySelector('.unit')!.textContent).toBe('참가 3명');
  });

  it('기본 정보 검사: 31일짜리 달의 월간 챌린지도 통과한다', () => {
    expect(challengeBasicsError({ name: '12월 챌린지', startDate: '2026-12-01', endDate: '2026-12-31', capacity: null })).toBeNull();
    expect(challengeBasicsError({ name: '긴 챌린지', startDate: '2026-12-01', endDate: '2026-12-31', capacity: 60 })).toBe('기간은 7~30일로 정해 주세요');
  });

  it('OP1 전환 안내: 집계 마감이면 OP4 에서 최종 확정한다고 말한다', async () => {
    const t = await visit('/c/ch-monthly/settings');
    expect(t).toContain('OP4에서 최종 확정');
    expect(t).not.toContain('진행 중에는 수동 전환이 없어요');
  });
});

describe('간식 임계 문구', () => {
  it('0 이면 "0 미만"이 아니라 기록이 있으면 끼니로 인정', () => {
    expect(snackRuleNote(0)).toBe('기록이 있으면 끼니로 인정');
    expect(snackRuleNote(150)).toBe('kcal 미만은 간식(슬롯 미충족)');
  });
});

describe('첫 요청이 느리거나 오류가 날 때', () => {
  const api = (ops: () => Promise<never>) => ({ kind: 'mock', ops, subscribe: () => () => {} }) as unknown as ConsoleApi;

  it('응답을 기다리는 동안 빈 화면 대신 불러오는 중', async () => {
    const h = await mount(<ConsoleProvider api={api(() => new Promise(() => {}))}><p>본문</p></ConsoleProvider>);
    expect(h.textContent).toContain('불러오는 중');
  });

  it('오류가 나면 안내와 다시 시도 버튼, 누르면 다시 요청', async () => {
    let calls = 0;
    const h = await mount(<ConsoleProvider api={api(() => { calls++; return Promise.reject(new Error('network')); })}><p>본문</p></ConsoleProvider>);
    expect(calls).toBe(1);
    const retry = [...h.querySelectorAll('button')].find((b) => /다시/.test(b.textContent ?? ''));
    expect(retry).toBeTruthy();
    await act(async () => { retry!.click(); });
    await settle();
    expect(calls).toBe(2);
  });
});
