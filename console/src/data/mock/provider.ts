/**
 * [모의 전용] 메모리 데이터 provider. VITE_SUPABASE_URL이 없을 때 쓴다.
 * 점수는 mock/engine.ts(TS 포트)로 계산하고, 서버 RPC와 같은 입출력 모양을 돌려준다.
 */
import type { ConsoleApi } from '../api';
import type {
  Announcement, AuditEntry, Challenge, ChallengeRules, ChallengeStatus, ChallengeSummary, CsvFile, CsvType, DayRow,
  FinalRanking, HealthAlert, OpsInfo, Participant, ParticipantAction, ParticipantState, PurgeResult, ReasonTemplate,
  ReviewEvidence, ReviewItem, SimInput, SimResult, Slot, Verdict, VerdictImpact,
} from '../types';
import { buildCsv } from '../../lib/csv';
import { fmt, mdDate, median, round1 as r1 } from '../../lib/format';
import { REASON_LABEL_BY_TYPE } from '../../lib/verdictCopy';
import { RULES, bmrOf, mockSimulate, mOf } from './engine';
import {
  AUDIT_SEED, DATES, FINAL_SEED, HEALTH_SEED, LEADERBOARD_OTHERS, PEOPLE_SEED, REVIEW_SEED, START, TODAY_MEAL_TITLES,
  buildDays, type MockDayInput, type MockMeal, type MockPersonSeed,
} from './seed';

const PRIMARY = 'ch-autumn';
const OPERATOR = '민호';

interface Scenario {
  key: string; label: string; status: ChallengeStatus; today: string; time: string; joined: number;
  sla?: Record<string, number>; decideAll?: boolean; publishedAt?: string; purged?: boolean;
}
const SCENARIOS: Scenario[] = [
  { key: 'draft', label: '초안', status: 'draft', today: '2026-10-01', time: '12:00', joined: 0 },
  { key: 'recruiting-empty', label: '모집 중(0명)', status: 'recruiting', today: '2026-10-03', time: '12:00', joined: 0 },
  { key: 'recruiting', label: '모집 중(42명)', status: 'recruiting', today: '2026-10-03', time: '12:00', joined: 42 },
  { key: 'running', label: '진행 중', status: 'running', today: '2026-10-13', time: '21:14', joined: 42 },
  { key: 'running-sla-warn', label: 'SLA 임박', status: 'running', today: '2026-10-13', time: '21:14', joined: 42, sla: { 'rv-0412': 18 } },
  { key: 'closing', label: '집계 마감(미결 3)', status: 'closing', today: '2026-11-03', time: '09:30', joined: 42 },
  { key: 'closing-sla-critical', label: 'SLA 초과', status: 'closing', today: '2026-11-03', time: '09:30', joined: 42, sla: { 'rv-0412': -6 } },
  { key: 'closing-clear', label: '집계 마감(미결 0)', status: 'closing', today: '2026-11-03', time: '09:30', joined: 42, decideAll: true },
  { key: 'published', label: '결과 확정', status: 'published', today: '2026-11-07', time: '10:00', joined: 42, decideAll: true, publishedAt: '2026-11-03T09:30:00+09:00' },
  { key: 'archived', label: '종료(파기 전)', status: 'archived', today: '2026-11-11', time: '10:00', joined: 42, decideAll: true, publishedAt: '2026-11-03T09:30:00+09:00' },
  { key: 'archived-purged', label: '종료(파기 완료)', status: 'archived', today: '2026-11-11', time: '10:05', joined: 42, decideAll: true, publishedAt: '2026-11-03T09:30:00+09:00', purged: true },
];

const kstIso = (today: string, time: string) => `${today}T${time}:00+09:00`;
const sleep = <T,>(v: T): Promise<T> => Promise.resolve(v);

interface MockPerson {
  id: string; seed: MockPersonSeed; idx: number; age: number; bmr: number; days: MockDayInput[];
  sBefore: Record<string, number>; adjust: number; excluded: boolean; kicked: boolean; blocked: boolean; warns: number; note: string;
}
interface MockReview {
  id: string; shortId: string; type: 'steps_spike' | 'dup_photo' | 'report'; personId: string; localDate: string; slot: Slot | null;
  status: 'open' | 'appealed' | 'decided'; verdict: Verdict | null; reason: ReasonTemplate | null; dueMs: number; createdMs: number;
  appeal?: string; appealAt?: string; report?: string; reportAt?: string; decidedAt: string | null;
}

const OTHER_CHALLENGES: Challenge[] = [
  { id: 'ch-winter', name: '겨울 저녁 산책 챌린지', status: 'draft', startDate: '2026-12-07', endDate: '2027-01-03', capacity: 50, inviteCode: 'W3N7QA', rulesMd: '', photosPurgedAt: null, publishedAt: null, joined: 0 },
  { id: 'ch-summer', name: '여름 계단 챌린지', status: 'archived', startDate: '2026-07-06', endDate: '2026-08-02', capacity: 40, inviteCode: 'S5T9XP', rulesMd: '', photosPurgedAt: '2026-08-17T10:00:00+09:00', publishedAt: '2026-08-03T09:30:00+09:00', joined: 36 },
];

const DEFAULT_MD = '## 운영자 추가 규칙\n- 회식 날(10.17)은 저녁 자동 확정 대신 대체값 적용을 요청할 수 있어요(운영자에게 메시지).\n- 상품은 상위 3명 + 반영률 100% 달성자 추첨 2명.';

const DEFAULT_RULES: ChallengeRules = {
  t: RULES.T, c: RULES.C, mMin: RULES.M_MIN, mRatio: RULES.M_RATIO, fMin: RULES.F_MIN, fRatio: RULES.F_RATIO,
  snackKcal: RULES.SNACK_KCAL, stepsCap: RULES.STEPS_CAP, floorsCap: RULES.FLOORS_CAP, stepMet: RULES.MET_WALK,
  skipPerDay: RULES.SKIP_PER_DAY, skipPerWeek: RULES.SKIP_PER_WEEK, checkDays: RULES.CHECK_DAYS, nudgeMinM: 1500, nudgeMinF: 1200, lockedAt: null,
};

export function createMockApi(initialScenario?: string): ConsoleApi {
  const listeners = new Set<() => void>();
  const notify = () => listeners.forEach((f) => f());

  let scenario = SCENARIOS.find((s) => s.key === initialScenario) ?? SCENARIOS[3];
  let primary!: Challenge;
  let people: MockPerson[] = [];
  let reviews: MockReview[] = [];
  let audit: AuditEntry[] = [];
  let announcements: Announcement[] = [];
  let md = DEFAULT_MD;
  let completedBase = 12;

  const nowIso = () => kstIso(scenario.today, scenario.time);
  const nowLabel = () => `${mdDate(scenario.today)} ${scenario.time}`;
  const log = (text: string, by = OPERATOR) => { audit = [{ at: nowLabel(), by, text }, ...audit]; };

  function seed() {
    const s = scenario;
    primary = {
      id: PRIMARY, name: '가을 걷기 챌린지', status: s.status, startDate: START, endDate: '2026-11-02', capacity: 60,
      inviteCode: 'K7Q2MD', rulesMd: md, photosPurgedAt: s.purged ? nowIso() : null, publishedAt: s.publishedAt ?? null, joined: s.joined,
    };
    people = s.joined === 0 ? [] : PEOPLE_SEED.map((seedP, idx) => {
      const age = 2026 - seedP.birthYear;
      return {
        id: `p-${idx + 1}`, seed: seedP, idx, age, bmr: bmrOf(seedP.sex, seedP.weightKg, seedP.heightCm, age), days: buildDays(seedP, idx),
        sBefore: {}, adjust: 0, excluded: false, kicked: false, blocked: false, warns: seedP.warns, note: '',
      };
    });
    const byName = (n: string) => people.find((p) => p.seed.name === n);
    const now = Date.parse(nowIso());
    reviews = people.length === 0 ? [] : REVIEW_SEED.map((r) => ({
      id: r.id, shortId: r.shortId, type: r.type, personId: byName(r.who)!.id, localDate: r.localDate, slot: r.slot,
      status: s.decideAll ? 'decided' as const : r.status, verdict: s.decideAll ? 'approve' as const : null,
      reason: r.reason, dueMs: now + (s.sla?.[r.id] ?? r.slaHours) * 3600e3, createdMs: now - 8 * 3600e3,
      appeal: r.appeal, appealAt: r.appealAt, report: r.report, reportAt: r.reportAt, decidedAt: s.decideAll ? nowLabel() : null,
    }));
    audit = people.length ? AUDIT_SEED.map(([at, by, text]) => ({ at, by, text })) : [];
    announcements = [];
    completedBase = s.decideAll ? 15 : 12;
    md = DEFAULT_MD;
    primary.rulesMd = md;
  }
  seed();

  // ---------- 계산 보조 ----------
  const inputOf = (p: MockPerson, d: MockDayInput): SimInput => ({
    sex: p.seed.sex, weight_kg: p.seed.weightKg, height_cm: p.seed.heightCm, age: p.age,
    steps_total: d.steps, sessions: d.sessions, floors: 0, meals: d.meals,
  });
  const dayScore = (p: MockPerson, d: MockDayInput) => mockSimulate(inputOf(p, d));
  const isCheck = (i: number) => i < RULES.CHECK_DAYS;
  const isProvisional = (d: MockDayInput) => d.date === scenario.today && primary.status === 'running';

  function cumulative(p: MockPerson): number {
    if (p.seed.staticCum != null) return r1(p.seed.staticCum + p.adjust);
    return r1(p.days.reduce((a, d, i) => (isCheck(i) || d.date >= scenario.today && primary.status === 'running' ? a : a + dayScore(p, d).s_d), 0));
  }
  function rankOf(name: string, score: number): number {
    return 1 + LEADERBOARD_OTHERS.filter((x) => x.name !== name && x.score > score).length;
  }
  const reviewsOf = (p: MockPerson) => reviews.filter((r) => r.personId === p.id);
  const openOf = (p: MockPerson) => reviewsOf(p).filter((r) => r.status !== 'decided');

  function stateOf(p: MockPerson): ParticipantState {
    if (p.kicked) return 'kicked';
    if (p.excluded) return 'excluded';
    if (p.seed.unsynced) return 'unsynced';
    if (openOf(p).some((r) => r.type !== 'report')) return 'review';
    if (p.seed.recordReason) return 'record';
    return 'normal';
  }

  function toParticipant(p: MockPerson): Participant {
    const today = p.days[7];
    const r = dayScore(p, today);
    return {
      id: p.id, nickname: p.seed.name, sex: p.seed.sex, birthYear: p.seed.birthYear, heightCm: p.seed.heightCm, weightKg: p.seed.weightKg, bmr: p.bmr,
      state: stateOf(p), rankEligible: !p.excluded && !p.kicked, warningCount: p.warns, blockRejoin: p.blocked || p.kicked, operatorNote: p.note,
      lastSyncedAt: p.seed.unsynced ? p.seed.lastSync! : `${mdDate(DATES[7])} ${p.seed.syncAt}`, syncedToday: !p.seed.unsynced,
      source: p.seed.source, device: p.seed.device, platform: p.seed.platform, watch: !!p.seed.watch,
      todaySteps: today.steps, mealsToday: r.intake.main_meal_count, flagged: openOf(p).some((x) => x.type !== 'report'),
      recordModeReason: p.seed.recordReason ?? null,
    };
  }

  function evidenceOf(rv: MockReview, p: MockPerson): ReviewEvidence {
    if (rv.type === 'steps_spike') {
      const days = p.days.slice(0, 7);
      return {
        steps7: days.map((d) => ({ label: mdDate(d.date), steps: d.steps })),
        stepsBaseline: median(p.days.slice(0, RULES.CHECK_DAYS).map((d) => d.steps)),
        stepsSource: `${p.seed.source} · ${p.seed.device}`,
        sessionNote: '없음 · 걸음만 동기화',
      };
    }
    const day = p.days.find((d) => d.date === rv.localDate)!;
    const meal = day.meals.find((m) => m.slot === rv.slot);
    if (rv.type === 'dup_photo') {
      return {
        photoPair: { hash: 'a3f9 2c17 … c21e', labelA: '10.11 저녁 · 원본', labelB: '10.12 저녁 · 같은 사진' },
        ai: { title: TODAY_MEAL_TITLES.dinner, aiKcal: 640, confirmedKcal: 600, substituteKcal: Math.round(mOf(p.bmr)) },
      };
    }
    return {
      photo: { hash: '7be0 91aa … 04d3', label: `${mdDate(rv.localDate)} 점심 · 12:41` },
      ai: { title: '(AI 초안 없음 · 검색으로 확정)', aiKcal: null, confirmedKcal: meal?.kcal ?? null, substituteKcal: Math.round(mOf(p.bmr)) },
    };
  }

  function toReview(rv: MockReview): ReviewItem {
    const p = people.find((x) => x.id === rv.personId)!;
    return {
      id: rv.id, shortId: rv.shortId, type: rv.type, label: REASON_LABEL_BY_TYPE[rv.type], participantId: p.id, nickname: p.seed.name,
      localDate: rv.localDate, dateLabel: mdDate(rv.localDate), slot: rv.slot, status: rv.status, verdict: rv.verdict, reasonTemplate: rv.reason,
      slaDueAt: new Date(rv.dueMs).toISOString(), createdAt: new Date(rv.createdMs).toISOString(),
      appealText: rv.appeal ?? null, appealAt: rv.appealAt ?? null, reportText: rv.report ?? null, reportAt: rv.reportAt ?? null,
      warningCount: p.warns, evidence: evidenceOf(rv, p), decidedAt: rv.decidedAt, decidedBy: rv.decidedAt ? OPERATOR : null,
    };
  }

  /** apply_verdict 포트. dry=false면 상태를 바꾼다. */
  function applyVerdict(rv: MockReview, verdict: Verdict, reason: ReasonTemplate | null, dry: boolean): VerdictImpact {
    const p = people.find((x) => x.id === rv.personId)!;
    const dayIdx = p.days.findIndex((d) => d.date === rv.localDate);
    const day = p.days[dayIdx];
    const before = dayScore(p, day);
    const cumBefore = cumulative(p);
    const rankBefore = rankOf(p.seed.name, cumBefore);
    const mp = mOf(p.bmr);
    const base: VerdictImpact = {
      local_date: rv.localDate, s_before: before.s_d, s_after: before.s_d, cumulative_before: cumBefore, cumulative_after: cumBefore,
      m_p: Math.round(mp), substitution: null, warning_count: p.warns, rank_before: rankBefore, rank_after: rankBefore,
    };
    let impact = base;
    let mutate: () => void = () => undefined;

    if (verdict === 'warn') {
      impact = { ...base, warning_count: Math.min(3, p.warns + 1) };
      mutate = () => { p.warns = Math.min(3, p.warns + 1); if (p.warns >= 3) p.excluded = true; };
    } else if (verdict === 'exclude') {
      impact = { ...base, warning_count: 3 };
      mutate = () => { p.warns = 3; p.excluded = true; };
    } else if (verdict === 'void') {
      let after = before; let substitution = 'm_p'; let newDay: MockDayInput = day; let detail = '';
      if (rv.type === 'steps_spike') {
        const baseline = median(p.days.slice(0, RULES.CHECK_DAYS).map((d) => d.steps));
        newDay = { ...day, steps: baseline };
        after = dayScore(p, newDay); substitution = 'baseline_steps';
        detail = `걸음 ${fmt.int(day.steps)} → 기준선 중앙값 ${fmt.int(baseline)} · A ${fmt.int(before.activity.a_d)} → ${fmt.int(after.activity.a_d)}`;
      } else {
        const label = { breakfast: '아침', lunch: '점심', dinner: '저녁', snack: '간식' }[rv.slot ?? 'dinner'];
        newDay = { ...day, meals: day.meals.map((m) => (m.slot === rv.slot ? { slot: m.slot, status: 'void' as const } : m)) };
        after = dayScore(p, newDay);
        detail = `${label} → 대체값 ${fmt.int(Math.round(mp))} · I ${fmt.int(before.intake.i_d)} → ${fmt.int(after.intake.i_d)} · D ${fmt.int(after.d_d)}`;
      }
      const delta = r1(after.s_d - before.s_d);
      const counted = !isCheck(dayIdx) && !isProvisional(day);
      const cumAfter = counted ? r1(cumBefore + delta) : cumBefore;
      impact = {
        ...base, s_after: after.s_d, cumulative_after: cumAfter, substitution, rank_after: rankOf(p.seed.name, cumAfter), detail,
        is_final: counted,
      };
      mutate = () => {
        p.sBefore[day.date] = before.s_d;
        p.days[dayIdx] = newDay;
        if (p.seed.staticCum != null && counted) p.adjust = r1(p.adjust + delta);
      };
    }
    if (!dry) {
      mutate();
      rv.status = 'decided'; rv.verdict = verdict; rv.reason = reason ?? rv.reason; rv.decidedAt = nowLabel();
      log(`검토 ${rv.shortId} 판정 확정: ${verdict} · ${reason ?? '-'} · N-06 발송${verdict === 'void' ? ' · score_revisions(reason=verdict)' : ''}`);
      if (verdict === 'exclude' || (verdict === 'warn' && p.warns >= 3)) log(`${p.seed.name} 순위 제외(경고 3회)`, '시스템');
      notify();
    }
    return impact;
  }

  const openCount = () => reviews.filter((r) => r.status !== 'decided').length;

  const api: ConsoleApi = {
    kind: 'mock',
    subscribe(fn) { listeners.add(fn); return () => { listeners.delete(fn); }; },
    mock: {
      scenarios: SCENARIOS.map(({ key, label }) => ({ key, label })),
      current: () => scenario.key,
      setScenario(key) {
        const s = SCENARIOS.find((x) => x.key === key);
        if (!s) return;
        scenario = s; seed(); notify();
      },
    },

    ops: () => sleep<OpsInfo>({ today: scenario.today, nowIso: nowIso(), syncedLabel: `${mdDate(scenario.today)} 21:10`, operatorName: OPERATOR }),

    async listChallenges(): Promise<ChallengeSummary[]> {
      const unsynced = people.filter((p) => p.seed.unsynced).length;
      const running = ['checking', 'running', 'closing'].includes(primary.status);
      return [
        { challenge: { ...primary }, openReviews: openCount(), todaySyncRate: primary.joined ? Math.round((primary.joined - (running ? unsynced : 0)) / primary.joined * 100) : null, unconfirmedMeals: running ? 17 : 0 },
        ...OTHER_CHALLENGES.map((c) => ({ challenge: { ...c }, openReviews: 0, todaySyncRate: null, unconfirmedMeals: 0 })),
      ];
    },
    async summary(id) {
      const all = await api.listChallenges();
      const f = all.find((x) => x.challenge.id === id);
      if (!f) throw new Error('챌린지를 찾지 못했어요');
      return f;
    },
    async getChallenge(id) {
      if (id === PRIMARY) return { ...primary, rulesMd: md };
      const c = OTHER_CHALLENGES.find((x) => x.id === id);
      if (!c) throw new Error('챌린지를 찾지 못했어요');
      return { ...c };
    },
    getRules: () => sleep({ ...DEFAULT_RULES, lockedAt: ['draft', 'recruiting'].includes(primary.status) ? null : `${START}T00:00:00+09:00` }),
    async updateChallenge(id, patch) {
      if (id !== PRIMARY) throw new Error('모의 데이터에서는 가을 걷기 챌린지만 수정할 수 있어요');
      if (!['draft', 'recruiting'].includes(primary.status)) throw new Error('시작 후에는 기간·정원이 바뀌지 않아요');
      Object.assign(primary, patch);
      log(`챌린지 설정 변경: ${Object.keys(patch).join(', ')}`);
      notify();
      return { ...primary };
    },
    async saveRulesMd(id, text) {
      if (id === PRIMARY) { md = text; primary.rulesMd = text; log('규칙 Markdown 게시 · P11 반영'); notify(); }
    },
    async transition(id, to) {
      if (id !== PRIMARY) throw new Error('모의 데이터에서는 가을 걷기 챌린지만 전환할 수 있어요');
      const from = primary.status;
      const ok: Record<string, ChallengeStatus[]> = {
        draft: ['recruiting', 'cancelled'], recruiting: ['draft', 'checking', 'cancelled'], checking: ['running'], running: ['closing'],
        closing: ['published'], published: ['archived'], archived: [], cancelled: [],
      };
      if (!ok[from].includes(to)) throw new Error(`${from}에서 ${to}로는 바꿀 수 없어요`);
      if (to === 'draft' && primary.joined > 0) throw new Error('참가자가 있으면 초안으로 돌아갈 수 없어요');
      if (to === 'published') {
        const n = openCount();
        if (n > 0) throw new Error(`미결 ${n}건이 있어 최종 확정을 할 수 없어요`);
        primary.publishedAt = nowIso();
      }
      primary.status = to;
      log(`상태 전환 ${from} → ${to}`);
      notify();
    },
    openReviewCount: async (id) => (id === PRIMARY ? openCount() : 0),

    simulate: (input) => sleep<SimResult>(mockSimulate(input)),

    listParticipants: async (id) => (id === PRIMARY ? people.map(toParticipant) : []),
    async participantDays(pid) {
      const p = people.find((x) => x.id === pid);
      if (!p) return [];
      return p.days.map<DayRow>((d, i) => {
        const r = dayScore(p, d);
        const sb = p.sBefore[d.date];
        return {
          date: d.date, label: mdDate(d.date), steps: d.steps, a: r.activity.a_d, i: r.intake.i_d, d: r.d_d, s: r.s_d,
          sBefore: sb ?? null, check: isCheck(i), provisional: isProvisional(d), revised: sb != null,
          floorApplied: r.floor_applied, underReview: reviews.some((x) => x.personId === pid && x.localDate === d.date && x.status !== 'decided'),
        };
      });
    },
    async participantAction(pid, action: ParticipantAction, memo) {
      const p = people.find((x) => x.id === pid);
      if (!p) throw new Error('참가자를 찾지 못했어요');
      if (action === 'exclude') p.excluded = true;
      if (action === 'kick') { p.kicked = true; p.blocked = true; }
      if (action === 'block') p.blocked = true;
      if (action === 'memo') p.note = memo;
      const label = { exclude: '순위 제외', kick: '강퇴 · 재가입 차단', block: '재가입 차단', memo: '메모 저장' }[action];
      log(`${p.seed.name} ${label}${memo && action !== 'memo' ? ` · 사유: ${memo}` : ''}`);
      notify();
    },
    async listHealthAlerts(id): Promise<HealthAlert[]> {
      if (id !== PRIMARY) return [];
      return people.length ? HEALTH_SEED.map((h) => ({ id: h.id, participantId: people.find((p) => p.seed.name === h.who)!.id, nickname: h.who, type: h.type, localDate: h.localDate, text: h.text, nudge: h.nudge })) : [];
    },

    listReviews: async (id) => (id === PRIMARY ? reviews.map(toReview) : []),
    async verdict(reviewId, verdict, reason, dryRun) {
      const rv = reviews.find((x) => x.id === reviewId);
      if (!rv) throw new Error('검토 건을 찾지 못했어요');
      if (!dryRun && rv.status === 'decided') throw new Error('이미 판정한 건이에요');
      return applyVerdict(rv, verdict, reason, dryRun);
    },
    auditLog: async () => audit,
    completedReviewCount: async () => completedBase + reviews.filter((r) => r.status === 'decided').length - (scenario.decideAll ? 3 : 0),

    async finalRanking(): Promise<FinalRanking> {
      const isFinal = ['published', 'archived'].includes(primary.status);
      return {
        rows: FINAL_SEED.map((r) => ({ rank: r.rank, nickname: r.name, score: r.score, confirmedMeals: r.meals, mealsTotal: 84, fill: Math.round(r.meals / 84 * 4) })),
        total: 42, hiddenExcluded: 2, isFinal, asOf: isFinal ? primary.publishedAt : null,
      };
    },
    async sendAnnouncement(_id, a) {
      announcements = [a, ...announcements];
      log(`공지 발송(N-03): ${a.title}`);
      notify();
      return { recipients: primary.joined };
    },
    async exportCsv(_id, type: CsvType): Promise<CsvFile> {
      const rows: Record<string, unknown>[] = [];
      if (type === 'ranking') FINAL_SEED.forEach((r) => rows.push({ rank: r.rank, nickname: r.name, score_total: r.score, confirmed_meals: r.meals }));
      for (const p of people) {
        p.days.forEach((d, i) => {
          const s = dayScore(p, d);
          const counted = !isCheck(i) && !isProvisional(d);
          if (type === 'scores') rows.push({ nickname: p.seed.name, local_date: d.date, steps: d.steps, a_d: s.activity.a_d, i_d: s.intake.i_d, d_d: s.d_d, s_d: s.s_d, is_counted: counted });
          if (type === 'meals') d.meals.forEach((m: MockMeal) => rows.push({ nickname: p.seed.name, local_date: d.date, slot: m.slot, status: m.status, confirmed_kcal: m.kcal ?? '' }));
          if (type === 'activity') rows.push({ nickname: p.seed.name, local_date: d.date, steps_total: d.steps, steps_net: s.activity.steps_net_kcal, sessions_net: s.activity.sessions_net_kcal, floors_bonus: s.activity.floors_kcal, a_capped: s.activity.a_d });
        });
      }
      return buildCsv(type, primary.inviteCode, rows);
    },
    photoCount: async () => 1247,
    async purgePhotos(): Promise<PurgeResult> {
      if (primary.status !== 'archived') throw new Error('종료(Archived) 뒤에만 파기할 수 있어요');
      primary.photosPurgedAt = nowIso();
      log('사진 원본 파기 1,247장');
      notify();
      return { count: 1247, purgedAt: primary.photosPurgedAt };
    },
  };
  return api;
}
