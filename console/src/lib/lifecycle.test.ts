import { describe, expect, it } from 'vitest';
import type { Challenge } from '../data/types';
import { ddayInfo, isLocked, manualTransitions, objectionDaysLeft } from './lifecycle';

const base: Challenge = {
  id: 'c1', name: '가을 걷기 챌린지', status: 'running', startDate: '2026-10-06', endDate: '2026-11-02', capacity: 60,
  inviteCode: 'K7Q2MD', rulesMd: '', photosPurgedAt: null, publishedAt: null, joined: 42,
};

describe('lifecycle', () => {
  it('D+8 (10.13)', () => {
    expect(ddayInfo(base, '2026-10-13').head).toBe('D+8');
  });
  it('모집 전 D-5', () => {
    expect(ddayInfo({ ...base, status: 'draft' }, '2026-10-01').head).toBe('D−5');
  });
  it('잠금과 수동 전환', () => {
    expect(isLocked('recruiting')).toBe(false);
    expect(isLocked('checking')).toBe(true);
    expect(manualTransitions('draft', 0).map((t) => t.to)).toEqual(['recruiting', 'cancelled']);
    expect(manualTransitions('recruiting', 3).map((t) => t.to)).toEqual(['cancelled']);
    expect(manualTransitions('running', 3)).toEqual([]);
  });
  it('이의 기간 7일 중 3일 남음', () => {
    const c = { ...base, status: 'published' as const, publishedAt: '2026-11-03T00:30:00Z' };
    expect(objectionDaysLeft(c, '2026-11-07')).toEqual({ elapsed: 4, left: 3 });
  });
});
