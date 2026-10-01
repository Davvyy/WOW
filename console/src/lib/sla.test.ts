import { describe, expect, it } from 'vitest';
import { hoursLeft, slaLevel, slaText } from './sla';

describe('sla', () => {
  const now = '2026-10-13T12:00:00Z';
  it('남은 시간 올림', () => {
    expect(hoursLeft('2026-10-15T05:00:00Z', now)).toBe(41);
    expect(hoursLeft('2026-10-13T12:30:00Z', now)).toBe(1);
  });
  it('임계값과 표기', () => {
    expect(slaLevel(41)).toBe('ok');
    expect(slaLevel(23)).toBe('warn');
    expect(slaLevel(-6)).toBe('critical');
    expect(slaText(18)).toBe('남은 18h · 임박');
    expect(slaText(-6)).toBe('+6h 초과');
    expect(slaText(41)).toBe('남은 41h');
  });
});
