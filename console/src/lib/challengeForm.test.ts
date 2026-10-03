import { describe, expect, it } from 'vitest';
import { challengeBasicsError, newChallengeDefaults } from './challengeForm';

const ok = { name: '봄 걷기 챌린지', startDate: '2026-10-05', endDate: '2026-11-01', capacity: 60 };

describe('챌린지 기본 정보 검사(F-OP-01: 기간 7~30일 · 정원 30~100명)', () => {
  it('올바르면 null', () => {
    expect(challengeBasicsError(ok)).toBeNull();
    expect(challengeBasicsError({ ...ok, endDate: '2026-10-11' })).toBeNull(); // 7일
    expect(challengeBasicsError({ ...ok, endDate: '2026-11-03' })).toBeNull(); // 30일
  });
  it('이름·기간·정원', () => {
    expect(challengeBasicsError({ ...ok, name: '  ' })).toBe('챌린지 이름을 입력해 주세요');
    expect(challengeBasicsError({ ...ok, endDate: '' })).toBe('기간을 입력해 주세요');
    expect(challengeBasicsError({ ...ok, endDate: '2026-10-10' })).toBe('기간은 7~30일로 정해 주세요');
    expect(challengeBasicsError({ ...ok, endDate: '2026-11-04' })).toBe('기간은 7~30일로 정해 주세요');
    expect(challengeBasicsError({ ...ok, capacity: 29 })).toBe('정원은 30~100명으로 정해 주세요');
    expect(challengeBasicsError({ ...ok, capacity: Number.NaN })).toBe('정원은 30~100명으로 정해 주세요');
  });
  it('새로 만들 때는 시작일이 오늘 이후, 수정할 때는 참가자 수 아래로 못 줄임', () => {
    expect(challengeBasicsError(ok, { today: '2026-10-06' })).toBe('시작일은 오늘 이후로 정해 주세요');
    expect(challengeBasicsError(ok, { today: '2026-10-05' })).toBeNull();
    expect(challengeBasicsError({ ...ok, capacity: 40 }, { joined: 42 })).toBe('현재 참가자 42명보다 적게 줄일 수 없어요');
  });
  it('새 챌린지 기본값: 내일 시작 · 28일 · 정원 60명(검사 통과)', () => {
    const d = newChallengeDefaults('2026-10-03');
    expect(d).toEqual({ name: '', startDate: '2026-10-04', endDate: '2026-10-31', capacity: 60 });
    expect(challengeBasicsError({ ...d, name: 'x' }, { today: '2026-10-03' })).toBeNull();
  });
});
