import { addDays, daysBetween } from './format';

export interface ChallengeBasics {
  name: string;
  startDate: string; // YYYY-MM-DD
  endDate: string;
  capacity: number | null;
}

/**
 * 기본 정보 검사(기능정의서 F-OP-01: 기간 7~30일 · 정원 30~100명). 서버 create_challenge 와 같은 규칙.
 * today 를 주면 새로 만들 때처럼 시작일이 오늘 이후여야 하고, joined 를 주면 수정할 때처럼 참가자 수 아래로 못 줄인다.
 */
export function challengeBasicsError(b: ChallengeBasics, opts: { today?: string; joined?: number } = {}): string | null {
  if (!b.name.trim()) return '챌린지 이름을 입력해 주세요';
  if (!b.startDate || !b.endDate) return '기간을 입력해 주세요';
  if (opts.today && b.startDate < opts.today) return '시작일은 오늘 이후로 정해 주세요';
  const days = daysBetween(b.startDate, b.endDate) + 1;
  // 월간 챌린지(정원 없음)는 그 달 전체라 28~31일이고, 기간·정원 규칙은 운영자가 만드는 챌린지에만 건다
  if (b.capacity == null) return null;
  if (!(days >= 7 && days <= 30)) return '기간은 7~30일로 정해 주세요';
  if (!(b.capacity >= 30 && b.capacity <= 100)) return '정원은 30~100명으로 정해 주세요';
  if (opts.joined && b.capacity < opts.joined) return `현재 참가자 ${opts.joined}명보다 적게 줄일 수 없어요`;
  return null;
}

/** 참가 인원 표기: 정원이 있으면 "N/정원", 없으면(월간) "N명" */
export function joinedLabel(c: { joined: number; capacity: number | null }): string {
  return c.capacity == null ? `${c.joined}명` : `${c.joined}/${c.capacity}`;
}

/** 간식 임계 설명. 0 이면 기록이 있는 끼니는 모두 슬롯을 채운다(D59) */
export function snackRuleNote(snackKcal: number): string {
  return snackKcal > 0 ? 'kcal 미만은 간식(슬롯 미충족)' : '기록이 있으면 끼니로 인정';
}

/** 새 챌린지 폼 기본값: 내일 시작 · 28일(4주) · 정원 60명 */
export function newChallengeDefaults(today: string): ChallengeBasics {
  const startDate = addDays(today, 1);
  return { name: '', startDate, endDate: addDays(startDate, 27), capacity: 60 };
}
