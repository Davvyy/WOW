import type {
  Announcement, AuditEntry, Challenge, ChallengeRules, ChallengeStatus, ChallengeSummary, CsvFile, CsvType,
  DayRow, FinalRanking, HealthAlert, OpsInfo, Participant, ParticipantAction, PurgeResult, ReasonTemplate,
  ReviewItem, SimInput, SimResult, Verdict, VerdictImpact,
} from './types';

/**
 * 콘솔의 모든 데이터 접근은 이 인터페이스를 거친다.
 * 구현은 mock(`data/mock`)과 supabase(`data/supabaseProvider.ts`) 두 가지이고 `data/index.ts`가 고른다.
 */
export interface ConsoleApi {
  readonly kind: 'mock' | 'supabase';

  ops(): Promise<OpsInfo>;

  listChallenges(): Promise<ChallengeSummary[]>;
  summary(id: string): Promise<ChallengeSummary>;
  getChallenge(id: string): Promise<Challenge>;
  getRules(challengeId: string): Promise<ChallengeRules>;
  /** 시작 전(draft/recruiting)에만 허용. 이름·기간·정원. */
  updateChallenge(id: string, patch: Partial<Pick<Challenge, 'name' | 'startDate' | 'endDate' | 'capacity'>>): Promise<Challenge>;
  /** 시작 후에도 허용. */
  saveRulesMd(id: string, md: string): Promise<void>;
  /** RPC transition_challenge. 미결이 있을 때 published로 가면 오류. */
  transition(id: string, to: ChallengeStatus): Promise<void>;
  /** RPC challenge_open_review_count */
  openReviewCount(challengeId: string): Promise<number>;

  /** RPC score_simulate_from_inputs (모의 경로는 mock 전용 TS 포트) */
  simulate(input: SimInput): Promise<SimResult>;

  listParticipants(challengeId: string): Promise<Participant[]>;
  participantDays(participantId: string): Promise<DayRow[]>;
  participantAction(participantId: string, action: ParticipantAction, memo: string): Promise<void>;
  listHealthAlerts(challengeId: string): Promise<HealthAlert[]>;

  listReviews(challengeId: string): Promise<ReviewItem[]>;
  /** dry_run=true는 저장하지 않고 점수 영향만 돌려준다. */
  verdict(reviewId: string, verdict: Verdict, reason: ReasonTemplate | null, dryRun: boolean): Promise<VerdictImpact>;
  auditLog(challengeId: string): Promise<AuditEntry[]>;
  completedReviewCount(challengeId: string): Promise<number>;

  finalRanking(challengeId: string): Promise<FinalRanking>;
  sendAnnouncement(challengeId: string, a: Announcement): Promise<{ recipients: number }>;
  exportCsv(challengeId: string, type: CsvType): Promise<CsvFile>;
  photoCount(challengeId: string): Promise<number>;
  purgePhotos(challengeId: string): Promise<PurgeResult>;

  /** 모의 전용: 시나리오 전환. supabase 구현에는 없다. */
  mock?: {
    scenarios: { key: string; label: string }[];
    current(): string;
    setScenario(key: string): void;
  };
  /** 데이터가 바뀌면 호출되는 구독. */
  subscribe(fn: () => void): () => void;
}
