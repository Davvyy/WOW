import { describe, expect, it } from 'vitest';
import type { VerdictImpact } from '../data/types';
import { REASON, VERDICT, composeNotification, ro, substitutionText } from './verdictCopy';

const voidImpact: VerdictImpact = {
  local_date: '2026-10-12',
  s_before: 41.2,
  s_after: 12.7,
  cumulative_before: 341.1,
  cumulative_after: 312.6,
  m_p: 742.5,
  substitution: '대체값 743',
  warning_count: 0,
};

describe('verdictCopy', () => {
  it('사유 템플릿 문자열이 06 문서와 같다', () => {
    expect(REASON.steps_spike).toBe('걸음 기록이 평소보다 크게 높아 확인했어요');
    expect(REASON.source_unknown).toBe('확인되지 않은 출처의 운동 기록이 있었어요');
    expect(REASON.dup_photo).toBe('같은 사진이 두 번 이상 사용됐어요');
    expect(REASON.downward_edit).toBe('확정값이 AI 추정보다 절반 넘게 낮았어요');
    expect(REASON.skip_abuse).toBe("'건너뜀'이 한도를 넘었어요");
    expect(VERDICT.approve.text).toBe('확인이 끝났어요');
    expect(VERDICT.exclude.text).toBe('경고가 3회 누적되어 이번 챌린지 순위에서 빠졌어요');
    expect(VERDICT.expired.text).toBe('설명 기간이 지나 기록으로만 확인했어요');
  });

  it('무효: 10.12 저녁 사진 중복 알림 문구', () => {
    const c = composeNotification({ reason: 'dup_photo', verdict: 'void', impact: voidImpact });
    expect(c?.text).toBe('같은 사진이 두 번 이상 사용됐어요. 대체값 743으로 다시 계산했어요. 10.12 41.2→12.7점 · 누적 −28.5');
    expect(c?.verdictSentence).toBe('대체값 743으로 다시 계산했어요');
    expect(c?.effectSentence).toBe('10.12 41.2→12.7점 · 누적 −28.5');
  });

  it('대체값은 m_p를 정수로 올림(BMR 1,650 → 743, 1,290 → 700, 1,730 → 779)', () => {
    expect(substitutionText({ substitution: null, m_p: 742.5 })).toBe('대체값 743');
    expect(substitutionText({ substitution: null, m_p: 700 })).toBe('대체값 700');
    expect(substitutionText({ substitution: null, m_p: 778.5 })).toBe('대체값 779');
    expect(substitutionText({ substitution: null, m_p: null })).toBe('대체 처리');
  });

  it('승인·경고·순위 제외', () => {
    expect(composeNotification({ reason: 'steps_spike', verdict: 'approve', impact: { ...voidImpact, s_after: 41.2 } })?.text)
      .toBe('걸음 기록이 평소보다 크게 높아 확인했어요. 확인이 끝났어요. 점수 변동 없음');
    expect(composeNotification({ reason: 'skip_abuse', verdict: 'warn', impact: { ...voidImpact, warning_count: 2 } })?.text)
      .toBe("'건너뜀'이 한도를 넘었어요. 이번은 경고 2/3이에요. 점수 변동 없음");
    expect(composeNotification({ reason: 'dup_photo', verdict: 'exclude', impact: { ...voidImpact, warning_count: 3 } })?.text)
      .toBe('같은 사진이 두 번 이상 사용됐어요. 경고가 3회 누적되어 이번 챌린지 순위에서 빠졌어요. 점수와 기록은 계속 볼 수 있어요');
  });

  it('다른 대체 처리 문구', () => {
    expect(substitutionText({ substitution: '평소 걸음 기준', m_p: null })).toBe('평소 걸음 기준');
    const c = composeNotification({ reason: 'steps_spike', verdict: 'void', impact: { ...voidImpact, substitution: '평소 걸음 기준', s_before: 100, s_after: 62.4 } });
    expect(c?.verdictSentence).toBe('평소 걸음 기준으로 다시 계산했어요');
  });

  it('사유·판정·영향 중 하나라도 없으면 문구를 만들지 않는다', () => {
    expect(composeNotification({ reason: null, verdict: 'void', impact: voidImpact })).toBeNull();
    expect(composeNotification({ reason: 'dup_photo', verdict: null, impact: voidImpact })).toBeNull();
    expect(composeNotification({ reason: 'dup_photo', verdict: 'void', impact: null })).toBeNull();
  });

  it('소명 기간 만료 부가 문장', () => {
    const c = composeNotification({ reason: 'steps_spike', verdict: 'approve', impact: voidImpact, expired: true });
    expect(c?.text).toContain('설명 기간이 지나 기록으로만 확인했어요');
  });

  it('조사 으로/로', () => {
    expect(ro('대체값 743')).toBe('으로');
    expect(ro('대체값 700')).toBe('으로');
    expect(ro('평소 걸음 기준')).toBe('으로');
    expect(ro('해당 출처 제외')).toBe('로');
    expect(ro('대체값 745')).toBe('로');
  });
});
