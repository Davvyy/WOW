/**
 * Supabase provider. supabase/migrations 계약(테이블·RPC·Edge Function 이름)에 맞춰 호출한다.
 * 계약에 없거나 아직 없는 것은 이 파일 안에서만 처리하고(README "열린 이슈" 참고) 화면은 ConsoleApi만 본다.
 */
import type { ConsoleApi } from './api';
import { hasSupabaseEnv, supabase } from './supabaseClient';
import type {
  Announcement, AuditEntry, Challenge, ChallengeRules, ChallengeStatus, ChallengeSummary, CsvFile, CsvType, DayRow,
  FinalRanking, HealthAlert, OpsInfo, Participant, ParticipantAction, ParticipantState, PurgeResult, ReasonTemplate,
  ReviewEvidence, ReviewItem, ReviewType, SimInput, SimResult, Slot, Verdict, VerdictImpact,
} from './types';
import { buildCsv } from '../lib/csv';
import { addDays, mdDate, mdTime, median } from '../lib/format';
import { healthAlertText } from '../lib/healthText';
import { REASON_LABEL_BY_TYPE } from '../lib/verdictCopy';

export { hasSupabaseEnv };

type Row = Record<string, any>; // eslint 없음. 컬럼이 늘어도 화면이 깨지지 않게 느슨하게 받는다.

function fail(what: string, error: { message?: string } | null): never {
  throw new Error(`${what}: ${error?.message ?? '알 수 없는 오류'}`);
}

const kstToday = () => new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
const num = (v: unknown, d = 0) => (v == null || Number.isNaN(Number(v)) ? d : Number(v));

function mapChallenge(r: Row, joined: number): Challenge {
  return {
    id: r.id, name: r.name, status: r.status, startDate: r.start_date, endDate: r.end_date, capacity: num(r.capacity),
    inviteCode: r.invite_code ?? '', rulesMd: r.rules_md ?? '', photosPurgedAt: r.photos_purged_at ?? null, publishedAt: r.published_at ?? null, joined,
  };
}

function mapRules(r: Row): ChallengeRules {
  return {
    t: num(r.t, 500), c: num(r.c, 1000), mMin: num(r.m_min, 700), mRatio: num(r.m_ratio, 0.45), fMin: num(r.f_min, 1200), fRatio: num(r.f_ratio, 0.8),
    snackKcal: num(r.snack_kcal, 150), stepsCap: num(r.steps_cap, 30000), floorsCap: num(r.floors_cap, 50), stepMet: num(r.step_met, 3.8),
    skipPerDay: num(r.skip_per_day, 1), skipPerWeek: num(r.skip_per_week, 3), checkDays: num(r.check_days, 3),
    nudgeMinM: num(r.nudge_min_m, 1500), nudgeMinF: num(r.nudge_min_f, 1200), lockedAt: r.locked_at ?? null,
  };
}

async function count(table: string, filter: (q: any) => any): Promise<number> {
  try {
    const { count: n, error } = await filter(supabase().from(table).select('id', { count: 'exact', head: true }));
    if (error) return 0;
    return n ?? 0;
  } catch { return 0; }
}

export function createSupabaseApi(): ConsoleApi {
  const sb = supabase();
  const listeners = new Set<() => void>();
  const notify = () => listeners.forEach((f) => f());

  async function audit(challengeId: string, action: string, detail: Record<string, unknown>) {
    // audit_logs는 서버(RPC·Edge Function)가 기록하는 것이 원칙. 화면에서 직접 남기는 조치만 최선으로 추가한다.
    try { await sb.from('audit_logs').insert({ challenge_id: challengeId, action, detail }); } catch { /* 계약 확정 전 */ }
  }

  async function challengeOfParticipant(pid: string) {
    const { data, error } = await sb.from('participants').select('challenge_id').eq('id', pid).single();
    if (error) fail('참가자를 불러오지 못했어요', error);
    return data.challenge_id as string;
  }

  const api: ConsoleApi = {
    kind: 'supabase',
    subscribe(fn) { listeners.add(fn); return () => { listeners.delete(fn); }; },

    async ops(): Promise<OpsInfo> {
      const { data } = await sb.auth.getUser();
      const now = new Date();
      return {
        today: kstToday(), nowIso: now.toISOString(), syncedLabel: mdTime(now.toISOString()),
        operatorName: (data.user?.user_metadata?.name as string | undefined) ?? data.user?.email ?? '운영자',
      };
    },

    async listChallenges(): Promise<ChallengeSummary[]> {
      const { data, error } = await sb.from('challenges').select('*').order('start_date', { ascending: false });
      if (error) fail('챌린지 목록을 불러오지 못했어요', error);
      const today = kstToday();
      return Promise.all((data as Row[]).map(async (r) => {
        const joined = await count('participants', (q) => q.eq('challenge_id', r.id));
        const synced = await count('participants', (q) => q.eq('challenge_id', r.id).gte('last_synced_at', `${today}T00:00:00+09:00`));
        const open = await api.openReviewCount(r.id).catch(() => 0);
        const live = ['checking', 'running', 'closing'].includes(r.status);
        const unconfirmed = live ? await count('meals', (q) => q.eq('challenge_id', r.id).in('status', ['captured', 'draft'])) : 0;
        return { challenge: mapChallenge(r, joined), openReviews: open, todaySyncRate: joined && live ? Math.round(synced / joined * 100) : null, unconfirmedMeals: unconfirmed };
      }));
    },
    async getChallenge(id) {
      const { data, error } = await sb.from('challenges').select('*').eq('id', id).single();
      if (error) fail('챌린지를 불러오지 못했어요', error);
      return mapChallenge(data, await count('participants', (q) => q.eq('challenge_id', id)));
    },
    async getRules(challengeId): Promise<ChallengeRules> {
      const { data, error } = await sb.from('challenge_rules').select('*').eq('challenge_id', challengeId).single();
      if (error) fail('규칙 상수를 불러오지 못했어요', error);
      return mapRules(data);
    },
    async updateChallenge(id, patch) {
      const body: Row = {};
      if (patch.name !== undefined) body.name = patch.name;
      if (patch.startDate !== undefined) body.start_date = patch.startDate;
      if (patch.endDate !== undefined) body.end_date = patch.endDate;
      if (patch.capacity !== undefined) body.capacity = patch.capacity;
      const { error } = await sb.from('challenges').update(body).eq('id', id);
      if (error) fail('설정을 저장하지 못했어요', error);
      notify();
      return api.getChallenge(id);
    },
    async saveRulesMd(id, md) {
      const { error } = await sb.from('challenges').update({ rules_md: md }).eq('id', id);
      if (error) fail('규칙을 게시하지 못했어요', error);
      await audit(id, 'rules_md_publish', { length: md.length });
      notify();
    },
    async transition(id, to: ChallengeStatus) {
      const { error } = await sb.rpc('transition_challenge', { p_challenge_id: id, p_to: to });
      if (error) fail('상태를 바꾸지 못했어요', error);
      notify();
    },
    async openReviewCount(id) {
      const { data, error } = await sb.rpc('challenge_open_review_count', { p_challenge_id: id });
      if (error) fail('미결 건수를 불러오지 못했어요', error);
      return num(data);
    },

    async simulate(input: SimInput): Promise<SimResult> {
      const { data, error } = await sb.rpc('score_simulate_from_inputs', { p: input });
      if (error) fail('시뮬레이션을 계산하지 못했어요', error);
      return data as SimResult;
    },

    async listParticipants(challengeId): Promise<Participant[]> {
      const { data, error } = await sb.from('participants').select('*').eq('challenge_id', challengeId).order('nickname');
      if (error) fail('참가자를 불러오지 못했어요', error);
      const today = kstToday();
      const [{ data: openRows }, { data: acts }, { data: scores }] = await Promise.all([
        sb.from('reviews').select('participant_id, type, status').eq('challenge_id', challengeId).neq('status', 'decided'),
        sb.from('daily_activity').select('*').eq('local_date', today).in('participant_id', (data as Row[]).map((p) => p.id)),
        sb.from('daily_scores').select('participant_id, main_meal_count').eq('local_date', today).in('participant_id', (data as Row[]).map((p) => p.id)),
      ]);
      const opens = (openRows ?? []) as Row[];
      const actBy = new Map<string, Row>(((acts ?? []) as Row[]).map((a) => [a.participant_id, a]));
      const scBy = new Map<string, Row>(((scores ?? []) as Row[]).map((a) => [a.participant_id, a]));
      return (data as Row[]).map((p): Participant => {
        const flagged = opens.some((o) => o.participant_id === p.id && o.type !== 'report');
        const synced = p.last_synced_at ? new Date(p.last_synced_at).getTime() >= Date.parse(`${today}T00:00:00+09:00`) : false;
        const kicked = p.status === 'kicked';
        const excluded = p.rank_eligible === false;
        const recordReason = p.record_mode_reason ?? null;
        const state: ParticipantState = kicked ? 'kicked' : excluded ? 'excluded' : !synced ? 'unsynced' : flagged ? 'review' : recordReason ? 'record' : 'normal';
        const act = actBy.get(p.id) ?? {};
        return {
          id: p.id, nickname: p.nickname, sex: p.sex, birthYear: p.birth_year ?? null, heightCm: num(p.height_cm), weightKg: num(p.weight_locked), bmr: num(p.bmr_locked),
          state, rankEligible: p.rank_eligible !== false, warningCount: num(p.warning_count), blockRejoin: Boolean(p.block_rejoin), operatorNote: p.operator_note ?? '',
          lastSyncedAt: p.last_synced_at ? mdTime(p.last_synced_at) : null, syncedToday: synced,
          source: act.source ?? p.source ?? '-', device: p.device ?? '-', platform: p.platform ?? '-', watch: Boolean(act.has_watch ?? p.has_watch),
          todaySteps: num(act.steps_total ?? act.steps), mealsToday: num(scBy.get(p.id)?.main_meal_count), flagged,
          recordModeReason: recordReason,
        };
      });
    },
    async participantDays(pid): Promise<DayRow[]> {
      const cid = await challengeOfParticipant(pid);
      const [{ data: sc, error }, { data: acts }, { data: ch }, { data: rl }] = await Promise.all([
        sb.from('daily_scores').select('*').eq('participant_id', pid).order('local_date'),
        sb.from('daily_activity').select('*').eq('participant_id', pid),
        sb.from('challenges').select('start_date').eq('id', cid).single(),
        sb.from('challenge_rules').select('check_days').eq('challenge_id', cid).single(),
      ]);
      if (error) fail('일별 장부를 불러오지 못했어요', error);
      const stepsBy = new Map<string, number>(((acts ?? []) as Row[]).map((a) => [a.local_date, num(a.steps_total ?? a.steps)]));
      const checkDays = num(rl?.check_days, 3);
      return (sc as Row[]).map((r): DayRow => {
        const idx = ch ? Math.round((Date.parse(r.local_date) - Date.parse(ch.start_date)) / 86400e3) : 99;
        const bd = (r.breakdown ?? {}) as Row;
        return {
          date: r.local_date, label: mdDate(r.local_date), steps: stepsBy.get(r.local_date) ?? 0,
          a: num(r.a_d), i: num(r.i_d), d: num(r.d_d), s: num(r.s_d), sBefore: bd.s_before != null ? num(bd.s_before) : null,
          check: idx < checkDays, provisional: r.is_final === false, revised: bd.s_before != null,
          floorApplied: Boolean(bd.floor_applied), underReview: Boolean(r.under_review),
        };
      });
    },
    async participantAction(pid, action: ParticipantAction, memo) {
      const patch: Row =
        action === 'exclude' ? { rank_eligible: false }
        : action === 'kick' ? { status: 'kicked', rank_eligible: false, block_rejoin: true }
        : action === 'block' ? { block_rejoin: true }
        : { operator_note: memo };
      const { error } = await sb.from('participants').update(patch).eq('id', pid);
      if (error) fail('조치를 저장하지 못했어요', error);
      await audit(await challengeOfParticipant(pid), `participant_${action}`, { participant_id: pid, memo: action === 'memo' ? undefined : memo });
      notify();
    },
    async listHealthAlerts(challengeId): Promise<HealthAlert[]> {
      const { data, error } = await sb.from('health_alerts').select('*, participants(nickname)').eq('challenge_id', challengeId).order('local_date', { ascending: false });
      if (error) fail('건강 알림을 불러오지 못했어요', error);
      return (data as Row[]).map((h) => ({
        id: h.id ?? `${h.participant_id}-${h.type}-${h.local_date}`, participantId: h.participant_id, nickname: h.participants?.nickname ?? '-',
        type: h.type, localDate: h.local_date, text: healthAlertText(h.type, h.local_date),
        nudge: h.type === 'weight_drop' ? '운영자만 확인 · 푸시 없음' : '넛지 발송됨 (N-07)',
      }));
    },

    async listReviews(challengeId): Promise<ReviewItem[]> {
      const { data, error } = await sb.from('reviews').select('*, participants(nickname, warning_count), appeals(text, created_at)').eq('challenge_id', challengeId).order('sla_due_at');
      if (error) fail('검토 큐를 불러오지 못했어요', error);
      return Promise.all((data as Row[]).map(async (r, i): Promise<ReviewItem> => {
        const target = (r.target ?? {}) as Row;
        const localDate: string = target.local_date ?? String(r.created_at).slice(0, 10);
        const appeal = Array.isArray(r.appeals) ? r.appeals[0] : r.appeals;
        const evidence = await evidenceFor(r.participant_id, r.type, localDate, target);
        const type = r.type as ReviewType;
        return {
          id: r.id, shortId: `R-${String(i + 1).padStart(4, '0')}`, type, label: REASON_LABEL_BY_TYPE[type] ?? type,
          participantId: r.participant_id, nickname: r.participants?.nickname ?? '-', localDate, dateLabel: mdDate(localDate),
          slot: (target.slot as Slot | undefined) ?? null, status: r.status, verdict: r.verdict ?? null, reasonTemplate: r.reason_template ?? null,
          slaDueAt: r.sla_due_at, createdAt: r.created_at, appealText: appeal?.text ?? null, appealAt: appeal?.created_at ? mdTime(appeal.created_at) : null,
          reportText: type === 'report' ? (target.text ?? null) : null, reportAt: type === 'report' ? mdTime(r.created_at) : null,
          warningCount: num(r.participants?.warning_count), evidence, decidedAt: r.decided_at ? mdTime(r.decided_at) : null, decidedBy: r.decided_by ?? null,
        };
      }));
    },
    async verdict(reviewId, verdict: Verdict, reason: ReasonTemplate | null, dryRun): Promise<VerdictImpact> {
      if (dryRun) {
        const { data, error } = await sb.rpc('apply_verdict', { p_review_id: reviewId, p_verdict: verdict, p_dry_run: true });
        if (error) fail('점수 영향을 미리 계산하지 못했어요', error);
        return data as VerdictImpact;
      }
      // 확정은 알림(N-06)·감사 로그까지 처리하는 Edge Function `verdict`를 우선 쓰고, 없으면 RPC로 대체한다.
      const fn = await sb.functions.invoke('verdict', { body: { review_id: reviewId, verdict, reason_template: reason, dry_run: false } });
      if (!fn.error) { notify(); return ((fn.data as Row)?.impact ?? fn.data) as VerdictImpact; }
      const { data, error } = await sb.rpc('apply_verdict', { p_review_id: reviewId, p_verdict: verdict, p_dry_run: false });
      if (error) fail('판정을 저장하지 못했어요', error);
      if (reason) await sb.from('reviews').update({ reason_template: reason }).eq('id', reviewId);
      notify();
      return data as VerdictImpact;
    },
    async auditLog(challengeId): Promise<AuditEntry[]> {
      const { data, error } = await sb.from('audit_logs').select('*').eq('challenge_id', challengeId).order('created_at', { ascending: false }).limit(30);
      if (error) return [];
      return (data as Row[]).map((a) => ({ at: mdTime(a.created_at), by: a.actor_name ?? a.actor_id?.slice?.(0, 6) ?? '시스템', text: a.action + (a.detail ? ` · ${JSON.stringify(a.detail)}` : '') }));
    },
    completedReviewCount: (id) => count('reviews', (q) => q.eq('challenge_id', id).eq('status', 'decided')),

    async finalRanking(challengeId): Promise<FinalRanking> {
      const { data, error } = await sb.from('leaderboard_snapshots').select('*').eq('challenge_id', challengeId).order('as_of', { ascending: false }).limit(5);
      if (error) fail('최종 순위를 불러오지 못했어요', error);
      const snaps = (data ?? []) as Row[];
      const snap = snaps.find((s) => s.is_final) ?? snaps.find((s) => s.scope === 'cumulative') ?? snaps[0];
      const rows = ((snap?.rows ?? []) as Row[]).map((r, i) => {
        const meals = num(r.confirmed_meals), total = num(r.meals_total, 84);
        return { rank: num(r.rank, i + 1), nickname: r.nickname ?? r.name, score: num(r.score ?? r.score_total), confirmedMeals: meals, mealsTotal: total, fill: Math.round(meals / Math.max(1, total) * 4) };
      });
      return { rows: rows.slice(0, 5), total: rows.length, hiddenExcluded: 0, isFinal: Boolean(snap?.is_final), asOf: snap?.as_of ?? null };
    },
    async sendAnnouncement(challengeId, a: Announcement) {
      const { data, error } = await sb.functions.invoke('announce', { body: { challenge_id: challengeId, title: a.title, body: a.body } });
      if (error) fail('공지를 보내지 못했어요(Edge Function announce)', error);
      notify();
      return { recipients: num((data as Row)?.recipients ?? (data as Row)?.sent) };
    },
    async exportCsv(challengeId, type: CsvType): Promise<CsvFile> {
      const ch = await api.getChallenge(challengeId);
      const fn = await sb.functions.invoke(`export?type=${type}&challenge_id=${challengeId}`, { method: 'GET' });
      if (!fn.error && typeof fn.data === 'string') {
        return { filename: `${type}_${ch.inviteCode}.csv`, text: fn.data, rowCount: Math.max(0, fn.data.split('\n').length - 1) };
      }
      return clientCsv(challengeId, type, ch.inviteCode);
    },
    photoCount: (id) => count('photos', (q) => q.eq('challenge_id', id)),
    async purgePhotos(challengeId): Promise<PurgeResult> {
      const { data, error } = await sb.functions.invoke('purge-photos', { body: { challenge_id: challengeId } });
      if (error) fail('사진을 파기하지 못했어요(Edge Function purge-photos)', error);
      notify();
      return { count: num((data as Row)?.count), purgedAt: (data as Row)?.purged_at ?? new Date().toISOString() };
    },
  };

  async function evidenceFor(pid: string, type: string, localDate: string, target: Row): Promise<ReviewEvidence> {
    const ev: ReviewEvidence = {};
    try {
      if (type === 'steps_spike') {
        const from = addDays(localDate, -6);
        const { data } = await sb.from('daily_activity').select('*').eq('participant_id', pid).gte('local_date', from).lte('local_date', localDate).order('local_date');
        const rows = (data ?? []) as Row[];
        ev.steps7 = rows.map((r) => ({ label: mdDate(r.local_date), steps: num(r.steps_total ?? r.steps) }));
        ev.stepsBaseline = rows.length ? median(rows.slice(0, 3).map((r) => num(r.steps_total ?? r.steps))) : undefined;
        ev.stepsSource = rows.at(-1)?.source ?? undefined;
        ev.sessionNote = rows.at(-1)?.sessions_count ? `${rows.at(-1)!.sessions_count}건` : '없음 · 걸음만 동기화';
      } else {
        // 사진 해시·AI 초안/확정값은 target jsonb에 서버가 채워 준다고 가정(계약 확인 필요).
        if (target.photo_hash) ev.photoPair = { hash: String(target.photo_hash), labelA: String(target.label_a ?? '원본'), labelB: String(target.label_b ?? '중복') };
        if (target.ai_kcal != null || target.confirmed_kcal != null) {
          ev.ai = { title: String(target.title ?? ''), aiKcal: target.ai_kcal ?? null, confirmedKcal: target.confirmed_kcal ?? null, substituteKcal: target.m_p ?? null };
        }
      }
    } catch { /* 증거 일부만 보여도 판정 화면은 열린다 */ }
    return ev;
  }

  /** 서버 export가 없을 때만 쓰는 대체 생성. 열은 lib/csv의 허용 목록만 쓴다. */
  async function clientCsv(challengeId: string, type: CsvType, code: string): Promise<CsvFile> {
    const { data: ps } = await sb.from('participants').select('id, nickname').eq('challenge_id', challengeId);
    const nick = new Map<string, string>(((ps ?? []) as Row[]).map((p) => [p.id, p.nickname]));
    const ids = [...nick.keys()];
    const records: Row[] = [];
    if (type === 'ranking') {
      const r = await api.finalRanking(challengeId);
      r.rows.forEach((x) => records.push({ rank: x.rank, nickname: x.nickname, score_total: x.score, confirmed_meals: x.confirmedMeals }));
    } else if (type === 'scores' || type === 'activity') {
      const { data: sc } = await sb.from('daily_scores').select('*').in('participant_id', ids).order('local_date');
      const { data: ac } = await sb.from('daily_activity').select('*').in('participant_id', ids);
      const stepsBy = new Map<string, number>(((ac ?? []) as Row[]).map((a) => [`${a.participant_id}|${a.local_date}`, num(a.steps_total ?? a.steps)]));
      for (const r of (sc ?? []) as Row[]) {
        const steps = stepsBy.get(`${r.participant_id}|${r.local_date}`) ?? 0;
        const bd = (r.breakdown ?? {}) as Row;
        if (type === 'scores') records.push({ nickname: nick.get(r.participant_id), local_date: r.local_date, steps, a_d: r.a_d, i_d: r.i_d, d_d: r.d_d, s_d: r.s_d, is_counted: r.is_counted });
        else records.push({ nickname: nick.get(r.participant_id), local_date: r.local_date, steps_total: steps, steps_net: bd.steps_net_kcal, sessions_net: bd.sessions_net_kcal, floors_bonus: bd.floors_kcal, a_capped: r.a_d });
      }
    } else {
      const { data: ms } = await sb.from('meals').select('participant_id, local_date, slot, status, confirmed_kcal').in('participant_id', ids).order('local_date');
      for (const m of (ms ?? []) as Row[]) records.push({ nickname: nick.get(m.participant_id), local_date: m.local_date, slot: m.slot, status: m.status, confirmed_kcal: m.confirmed_kcal });
    }
    return buildCsv(type, code, records);
  }

  return api;
}
