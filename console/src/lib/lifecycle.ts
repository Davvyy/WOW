import type { Challenge, ChallengeStatus } from '../data/types';
import { addDays, daysBetween, mdDate } from './format';

export interface StatusMeta { label: string; en: string; kind: 'neutral' | 'brand' | 'review' | 'good' | 'warn' | 'critical'; icon: string }

/** 03 §7 챌린지 8상태 — 색 + 아이콘 + 텍스트 */
export const STATUS: Record<ChallengeStatus, StatusMeta> = {
  draft: { label: '초안', en: 'Draft', kind: 'neutral', icon: 'edit_note' },
  recruiting: { label: '모집 중', en: 'Recruiting', kind: 'brand', icon: 'campaign' },
  checking: { label: '점검 기간', en: 'Checking', kind: 'review', icon: 'hourglass_top' },
  running: { label: '진행 중', en: 'Running', kind: 'good', icon: 'play_circle' },
  closing: { label: '집계 마감', en: 'Closing', kind: 'warn', icon: 'lock_clock' },
  published: { label: '결과 확정', en: 'Published', kind: 'brand', icon: 'verified' },
  archived: { label: '종료', en: 'Archived', kind: 'neutral', icon: 'inventory_2' },
  cancelled: { label: '취소', en: 'Cancelled', kind: 'critical', icon: 'cancel' },
};

export const FLOW: ChallengeStatus[] = ['draft', 'recruiting', 'checking', 'running', 'closing', 'published', 'archived'];

/** 시작 후(점검 기간 진입 이후)는 기간·정원·상수가 잠긴다. */
export function isLocked(s: ChallengeStatus): boolean {
  return !['draft', 'recruiting'].includes(s);
}

/** 운영자가 버튼으로 할 수 있는 전환만. 나머지는 배치가 자동 전환(03 §7). */
export function manualTransitions(s: ChallengeStatus, joined: number): { to: ChallengeStatus; label: string; danger?: boolean }[] {
  switch (s) {
    case 'draft': return [{ to: 'recruiting', label: '모집 시작' }, { to: 'cancelled', label: '취소', danger: true }];
    case 'recruiting': return [
      ...(joined === 0 ? [{ to: 'draft' as const, label: '초안으로(참가자 0명일 때)' }] : []),
      { to: 'cancelled', label: '취소(참가자에게 공지)', danger: true },
    ];
    default: return [];
  }
}

export function objectionUntil(c: Pick<Challenge, 'publishedAt'>): string | null {
  if (!c.publishedAt) return null;
  return addDays(new Date(Date.parse(c.publishedAt) + 9 * 3600e3).toISOString().slice(0, 10), 7);
}

export function ddayInfo(c: Challenge, today: string): { head: string; sub: string } {
  const range = `${mdDate(c.startDate)}~${mdDate(c.endDate)}`;
  const total = daysBetween(c.startDate, c.endDate) + 1;
  switch (c.status) {
    case 'draft':
    case 'recruiting': {
      const n = daysBetween(today, c.startDate);
      return { head: n > 0 ? `D−${n}` : 'D-Day', sub: `시작 ${mdDate(c.startDate)} · ${range} · ${total}일` };
    }
    case 'checking':
    case 'running': {
      const k = daysBetween(c.startDate, today) + 1;
      const left = Math.max(0, daysBetween(today, c.endDate));
      return { head: `D+${k}`, sub: `${mdDate(today)} · 종료 ${mdDate(c.endDate)} · 남은 ${left}일` };
    }
    case 'closing':
      return { head: `D+${daysBetween(c.startDate, today) + 1}`, sub: `${mdDate(addDays(c.endDate, 1))} 09:00 확정 배치 완료 · 미결 처리 중` };
    case 'published': {
      const until = objectionUntil(c);
      const left = until ? Math.max(0, daysBetween(today, until)) : 7;
      return { head: `이의 D−${left}`, sub: until ? `이의 기간 ~${mdDate(until)} (7일 중 ${left}일 남음)` : '이의 기간 7일' };
    }
    case 'archived': return { head: '종료', sub: '이의 기간 종료 · 열람 전용' };
    case 'cancelled': return { head: '취소', sub: '참가자에게 공지됨' };
  }
}

export function objectionDaysLeft(c: Pick<Challenge, 'publishedAt'>, today: string): { elapsed: number; left: number } {
  const until = objectionUntil(c);
  if (!until) return { elapsed: 0, left: 7 };
  const left = Math.max(0, Math.min(7, daysBetween(today, until)));
  return { elapsed: 7 - left, left };
}
