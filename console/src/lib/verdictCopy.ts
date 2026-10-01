/**
 * 판정 통지 문구 템플릿 — docs/06-화면-설계.md §6 "판정 사유 템플릿"과 prototype/data.js의 REASON/VERDICT와 같은 문자열.
 * 통지 문장 = 사유 문장 + 판정 문장 + 점수 영향 문장. 이 모듈 밖에서 판정 문구를 직접 만들지 않는다.
 */
import type { ReasonTemplate, Verdict, VerdictImpact } from '../data/types';
import { fmt } from './format';

export const REASON: Record<ReasonTemplate, string> = {
  steps_spike: '걸음 기록이 평소보다 크게 높아 확인했어요',
  source_unknown: '확인되지 않은 출처의 운동 기록이 있었어요',
  dup_photo: '같은 사진이 두 번 이상 사용됐어요',
  downward_edit: '확정값이 AI 추정보다 절반 넘게 낮았어요',
  skip_abuse: "'건너뜀'이 한도를 넘었어요",
};

export const REASON_KEYS = Object.keys(REASON) as ReasonTemplate[];

export interface VerdictTemplate { label: string; text: string; effect: string }

/** text/effect 안의 {…}는 composeNotification이 채운다. */
export const VERDICT: Record<Verdict, VerdictTemplate> & { expired: VerdictTemplate } = {
  approve: { label: '승인', text: '확인이 끝났어요', effect: '점수 변동 없음' },
  warn: { label: '경고', text: '이번은 경고 {n}/3이에요', effect: '점수 변동 없음' },
  void: { label: '무효', text: '{대체 처리}로 다시 계산했어요', effect: '{날짜} {전}→{후}점 · 누적 {차액}' },
  exclude: { label: '순위 제외', text: '경고가 3회 누적되어 이번 챌린지 순위에서 빠졌어요', effect: '점수와 기록은 계속 볼 수 있어요' },
  expired: { label: '소명 기간 만료', text: '설명 기간이 지나 기록으로만 확인했어요', effect: '' },
};

export const VERDICT_KEYS: Verdict[] = ['approve', 'warn', 'void', 'exclude'];

export const REASON_LABEL_BY_TYPE: Record<string, string> = {
  steps_spike: '걸음 급증',
  session_anomaly: '세션 이상',
  manual_input_burst: '수동 입력 급증',
  multi_device: '다중 기기',
  late_upload: '지연 업로드',
  photo_mismatch: '사진 불일치',
  source_unknown: '출처 확인',
  dup_photo: '사진 중복',
  downward_edit: '하향 수정',
  skip_abuse: '건너뜀 초과',
  report: '신고(기타)',
  objection: '이의',
};

/** 조사 '(으)로': 받침 없음·ㄹ 받침·숫자 1,2,4,5,7,8,9 → '로', 그 외 → '으로' */
export function ro(word: string): '로' | '으로' {
  const ch = String(word).trim().slice(-1);
  if (/[0-9]/.test(ch)) return '1245789'.includes(ch) ? '로' : '으로';
  const code = ch.charCodeAt(0);
  if (code < 0xAC00 || code > 0xD7A3) return '로';
  const fin = (code - 0xAC00) % 28;
  return fin === 0 || fin === 8 ? '로' : '으로';
}

/**
 * {대체 처리} 구절. 서버(apply_verdict)가 만든 `substitution` 구절을 그대로 쓰고,
 * 없으면 m_p를 정수로 올림해 "대체값 N"으로 만든다(서버와 같은 규칙).
 */
export function substitutionText(impact: Pick<VerdictImpact, 'substitution' | 'm_p'>): string {
  if (impact.substitution) return impact.substitution;
  return impact.m_p != null ? `대체값 ${fmt.int(Math.ceil(impact.m_p))}` : '대체 처리';
}

export interface ComposeInput {
  reason: ReasonTemplate | null;
  verdict: Verdict | null;
  impact: VerdictImpact | null;
  /** 소명 기간(72h)이 지난 뒤 판정하는 경우 (부가 문장 추가) */
  expired?: boolean;
}

export interface Composed {
  reasonSentence: string;
  verdictSentence: string;
  effectSentence: string;
  expiredSentence: string | null;
  /** 점수 영향 문장 중 누적 차액 등에 쓴 값 */
  text: string;
}

export function verdictSentence(verdict: Verdict, impact: VerdictImpact): string {
  if (verdict === 'warn') return VERDICT.warn.text.replace('{n}', String(impact.warning_count));
  if (verdict === 'void') {
    const sub = substitutionText(impact);
    return VERDICT.void.text.replace('{대체 처리}로', sub + ro(sub));
  }
  return VERDICT[verdict].text;
}

export function effectSentence(verdict: Verdict, impact: VerdictImpact): string {
  if (verdict !== 'void') return VERDICT[verdict].effect;
  const delta = impact.cumulative_after - impact.cumulative_before; // 누적 차액(서버 verdict_message와 같은 기준)
  return VERDICT.void.effect
    .replace('{날짜}', fmtMd(impact.local_date))
    .replace('{전}', fmt.k1(impact.s_before))
    .replace('{후}', fmt.k1(impact.s_after))
    .replace('{차액}', fmt.signed1(delta));
}

function fmtMd(iso: string): string {
  return `${+iso.slice(5, 7)}.${+iso.slice(8, 10)}`;
}

/** 당사자에게 보내는 알림 문구. 사유·판정·점수 영향이 모두 정해지기 전에는 null. */
export function composeNotification(input: ComposeInput): Composed | null {
  const { reason, verdict, impact } = input;
  if (!reason || !verdict || !impact) return null;
  const reasonS = REASON[reason];
  const verdictS = verdictSentence(verdict, impact);
  const effectS = effectSentence(verdict, impact);
  const expiredS = input.expired ? VERDICT.expired.text : null;
  const parts = [reasonS, verdictS, ...(expiredS ? [expiredS] : []), effectS].filter(Boolean);
  return {
    reasonSentence: reasonS,
    verdictSentence: verdictS,
    effectSentence: effectS,
    expiredSentence: expiredS,
    text: parts.join('. '),
  };
}
