/* 콘솔 도메인 타입. Supabase 컬럼(snake_case)은 provider에서 이 형태로 변환한다. */

export type ChallengeStatus =
  | 'draft' | 'recruiting' | 'checking' | 'running'
  | 'closing' | 'published' | 'archived' | 'cancelled';

export type ReviewType =
  | 'steps_spike' | 'source_unknown' | 'dup_photo' | 'downward_edit' | 'skip_abuse' | 'report' | 'objection';
export type ReasonTemplate = 'steps_spike' | 'source_unknown' | 'dup_photo' | 'downward_edit' | 'skip_abuse';
export type ReviewStatus = 'open' | 'appealed' | 'decided';
export type Verdict = 'approve' | 'warn' | 'void' | 'exclude';
export type Slot = 'breakfast' | 'lunch' | 'dinner' | 'snack';
export type HealthAlertType = 'low_intake_3d' | 'high_activity_3d' | 'weight_drop';
export type CsvType = 'ranking' | 'scores' | 'meals' | 'activity';
export type ParticipantAction = 'exclude' | 'kick' | 'block' | 'memo';

export interface Challenge {
  id: string;
  name: string;
  status: ChallengeStatus;
  startDate: string; // YYYY-MM-DD
  endDate: string;
  capacity: number;
  inviteCode: string;
  rulesMd: string;
  photosPurgedAt: string | null;
  publishedAt: string | null; // ISO
  joined: number;
}

export interface ChallengeRules {
  t: number; c: number;
  mMin: number; mRatio: number; fMin: number; fRatio: number;
  snackKcal: number; stepsCap: number; floorsCap: number; stepMet: number;
  skipPerDay: number; skipPerWeek: number; checkDays: number;
  nudgeMinM: number; nudgeMinF: number;
  lockedAt: string | null;
}

export interface ChallengeSummary {
  challenge: Challenge;
  openReviews: number;
  todaySyncRate: number | null; // 0~100, 참가자 0명이면 null
  unconfirmedMeals: number;
}

export interface OpsInfo {
  /** 오늘 날짜(YYYY-MM-DD). 모의 데이터는 시나리오 기준일을 돌려준다. */
  today: string;
  /** 현재 시각(ISO). SLA 계산 기준. */
  nowIso: string;
  /** 데이터 기준 시각 표기 (예: "10.13 21:10") */
  syncedLabel: string;
  operatorName: string;
}

export type ParticipantState = 'normal' | 'review' | 'unsynced' | 'record' | 'excluded' | 'kicked';

export interface Participant {
  id: string;
  nickname: string;
  sex: 'M' | 'F';
  birthYear: number | null;
  heightCm: number;
  weightKg: number;
  bmr: number;
  state: ParticipantState;
  rankEligible: boolean;
  warningCount: number;
  blockRejoin: boolean;
  operatorNote: string;
  lastSyncedAt: string | null; // 표시용 "10.13 21:10"
  syncedToday: boolean;
  source: string;   // 삼성헬스 · Apple 건강 …
  device: string;
  platform: string;
  watch: boolean;
  todaySteps: number;
  mealsToday: number; // 확정 끼니 0~3
  flagged: boolean;
  /** 운영자만 열람. 목록 표·CSV에는 쓰지 않는다. */
  recordModeReason: string | null;
}

export interface DayRow {
  date: string; // YYYY-MM-DD
  label: string; // "10.12"
  steps: number;
  a: number; i: number; d: number; s: number;
  sBefore: number | null;
  check: boolean;
  provisional: boolean;
  revised: boolean;
  floorApplied: boolean;
  underReview: boolean;
}

export interface HealthAlert {
  id: string;
  participantId: string;
  nickname: string;
  type: HealthAlertType;
  localDate: string;
  text: string;
  nudge: string;
}

export interface ReviewEvidence {
  steps7?: { label: string; steps: number }[];
  stepsBaseline?: number;
  stepsSource?: string;
  sessionNote?: string;
  photoPair?: { hash: string; labelA: string; labelB: string };
  photo?: { hash: string; label: string };
  ai?: { title: string; aiKcal: number | null; confirmedKcal: number | null; substituteKcal: number | null };
}

export interface ReviewItem {
  id: string;
  shortId: string;
  type: ReviewType;
  label: string;
  participantId: string;
  nickname: string;
  localDate: string; // YYYY-MM-DD
  dateLabel: string;
  slot: Slot | null;
  status: ReviewStatus;
  verdict: Verdict | null;
  reasonTemplate: ReasonTemplate | null;
  slaDueAt: string; // ISO
  createdAt: string;
  appealText: string | null;
  appealAt: string | null;
  reportText: string | null;
  reportAt: string | null;
  warningCount: number;
  evidence: ReviewEvidence;
  decidedAt: string | null;
  decidedBy: string | null;
}

/** apply_verdict RPC 결과 + 표시용 선택 필드 */
export interface VerdictImpact {
  local_date: string;
  s_before: number;
  s_after: number;
  cumulative_before: number;
  cumulative_after: number;
  m_p: number | null;
  /** 서버가 보내는 대체 처리 식별자. 모르는 값은 그대로 문장에 쓰지 않는다. */
  substitution: string | null;
  warning_count: number;
  /** 계약 밖 선택 필드(모의 데이터가 채움) */
  rank_before?: number;
  rank_after?: number;
  detail?: string;
  is_final?: boolean;
}

export interface AuditEntry { at: string; by: string; text: string }

export interface RankingRow { rank: number; nickname: string; score: number; confirmedMeals: number; mealsTotal: number; fill: number }
export interface FinalRanking {
  rows: RankingRow[];
  total: number;
  hiddenExcluded: number;
  isFinal: boolean;
  asOf: string | null;
}

export interface Announcement { title: string; body: string }

export interface CsvFile { filename: string; text: string; rowCount: number }

export interface SimInput {
  sex?: 'M' | 'F';
  weight_kg: number;
  height_cm?: number;
  age?: number;
  bmr?: number;
  steps_total: number;
  sessions: { type: 'running' | 'stair' | 'walking'; minutes: number; distance_m: number; steps_in_range: number }[];
  floors: number;
  meals: { slot: Slot; status: string; kcal?: number; ai_kcal?: number }[];
  challenge_id?: string;
}

export interface SimResult {
  bmr: number;
  m_p: number;
  f_p: number;
  activity: {
    steps_out: number; steps_net_kcal: number; sessions_net_kcal: number; floors_kcal: number;
    a_raw: number; a_d: number; a_capped: boolean;
  };
  intake: {
    i_d: number; main_meal_count: number; snack_count: number;
    substitute_slots: string[]; draft_slots: unknown[]; pending_slots: string[];
  };
  d_d: number;
  s_d: number;
  floor_applied: boolean;
}

export interface PurgeResult { count: number; purgedAt: string }
