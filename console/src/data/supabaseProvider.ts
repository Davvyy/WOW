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

const SLOT_KO: Record<Slot, string> = { breakfast: '아침', lunch: '점심', dinner: '저녁', snack: '간식' };
const RECORD_REASON: Record<string, string> = {
  minor: '미성년 안전 체크 · 기록 모드', bmi: 'BMI 안전 체크 · 기록 모드', pregnancy: '임신·수유 안전 체크 · 기록 모드', eating_disorder: '섭식 관련 안전 체크 · 기록 모드',
};
function sourceLabel(origin: string | null | undefined): string {
  if (!origin) return '-';
  if (/shealth/i.test(origin)) return '삼성헬스';
  if (/apple/i.test(origin)) return 'Apple 건강';
  if (/garmin/i.test(origin)) return 'Garmin';
  if (/fitbit/i.test(origin)) return 'Fitbit';
  if (/google|healthdata/i.test(origin)) return 'Health Connect';
  return origin;
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

  async function audit(challengeId: string, action: string, target: Record<string, unknown>) {
    // audit_logs는 append-only라 직접 쓰지 않고 log_operator_action RPC(actor = 본인 고정)로 남긴다.
    try {
      await sb.rpc('log_operator_action', { p_challenge_id: challengeId, p_action: action, p_target: target });
    } catch { /* 기록 실패는 화면 조치를 막지 않는다 */ }
  }

  async function challengeOfParticipant(pid: string) {
    const { data, error } = await sb.from('participants').select('challenge_id').eq('id', pid).single();
    if (error) fail('참가자를 불러오지 못했어요', error);
    return data.challenge_id as string;
  }

  async function summarize(r: Row): Promise<ChallengeSummary> {
    const today = kstToday();
    const joined = await count('participants', (q) => q.eq('challenge_id', r.id));
    const synced = await count('participants', (q) => q.eq('challenge_id', r.id).gte('last_synced_at', `${today}T00:00:00+09:00`));
    const open = await api.openReviewCount(r.id).catch(() => 0);
    const live = ['checking', 'running', 'closing'].includes(r.status);
    const unconfirmed = live ? await count('meals', (q) => q.eq('challenge_id', r.id).in('status', ['captured', 'draft'])) : 0;
    return { challenge: mapChallenge(r, joined), openReviews: open, todaySyncRate: joined && live ? Math.round(synced / joined * 100) : null, unconfirmedMeals: unconfirmed };
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
      return Promise.all((data as Row[]).map((r) => summarize(r)));
    },
    async summary(id) {
      const { data, error } = await sb.from('challenges').select('*').eq('id', id).single();
      if (error) fail('챌린지를 불러오지 못했어요', error);
      return summarize(data);
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
      // actor 는 서버가 auth.uid() 로 고정한다(transition_challenge_rpc)
      const { error } = await sb.rpc('transition_challenge_rpc', { p_challenge_id: id, p_to: to });
      if (error) {
        const m = /미결\s*(\d+)\s*건/.exec(error.message);
        if (m) throw new Error(`미결 ${m[1]}건이 있어 최종 확정을 할 수 없어요`);
        fail('상태를 바꾸지 못했어요', error);
      }
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
      const [{ data, error }, { data: chRow }] = await Promise.all([
        sb.from('participants').select('*, participant_notes(operator_note)').eq('challenge_id', challengeId).neq('status', 'left').order('nickname'),
        sb.from('challenges').select('status').eq('id', challengeId).single(),
      ]);
      if (error) fail('참가자를 불러오지 못했어요', error);
      const rows = data as Row[];
      const ids = rows.map((p) => p.id);
      const userIds = rows.map((p) => p.user_id).filter(Boolean);
      const today = kstToday();
      const live = ['checking', 'running', 'closing'].includes(chRow?.status);
      const [{ data: openRows }, { data: acts }, { data: scores }, { data: devs }, { data: profs }] = await Promise.all([
        sb.from('reviews').select('participant_id, type, status').eq('challenge_id', challengeId).in('status', ['open', 'appealed']),
        sb.from('daily_activity').select('participant_id, steps_total, sources').eq('local_date', today).in('participant_id', ids),
        sb.from('daily_scores').select('participant_id, main_meal_count').eq('local_date', today).in('participant_id', ids),
        sb.from('devices').select('user_id, platform').in('user_id', userIds),
        // 기록 모드 사유는 profiles에 있고 운영자만 볼 수 있다(RLS). 표·CSV에는 쓰지 않는다.
        sb.from('profiles').select('user_id, record_mode_reason').in('user_id', userIds).not('record_mode_reason', 'is', null),
      ]);
      const opens = (openRows ?? []) as Row[];
      const actBy = new Map<string, Row>(((acts ?? []) as Row[]).map((a) => [a.participant_id, a]));
      const scBy = new Map<string, Row>(((scores ?? []) as Row[]).map((a) => [a.participant_id, a]));
      const devBy = new Map<string, string>(((devs ?? []) as Row[]).map((d) => [d.user_id, d.platform]));
      const reasonBy = new Map<string, string>(((profs ?? []) as Row[]).map((d) => [d.user_id, d.record_mode_reason]));
      return rows.map((p): Participant => {
        const flagged = opens.some((o) => o.participant_id === p.id && o.type !== 'report');
        const synced = p.last_synced_at ? Date.parse(p.last_synced_at) >= Date.parse(`${today}T00:00:00+09:00`) : false;
        const kicked = p.status === 'kicked';
        const excluded = p.status === 'excluded' || p.rank_eligible === false;
        const state: ParticipantState = kicked ? 'kicked' : excluded ? 'excluded' : live && !synced ? 'unsynced' : flagged ? 'review' : p.status === 'record_mode' ? 'record' : 'normal';
        const act = actBy.get(p.id) ?? {};
        const platform = devBy.get(p.user_id);
        const note = Array.isArray(p.participant_notes) ? p.participant_notes[0] : p.participant_notes;
        return {
          id: p.id, nickname: p.nickname, sex: p.sex, birthYear: p.birth_year ?? null, heightCm: num(p.height_cm), weightKg: num(p.weight_locked), bmr: num(p.bmr_locked),
          state, rankEligible: p.rank_eligible !== false, warningCount: num(p.warning_count), blockRejoin: Boolean(p.block_rejoin), operatorNote: note?.operator_note ?? '',
          lastSyncedAt: p.last_synced_at ? mdTime(p.last_synced_at) : null, syncedToday: synced,
          source: sourceLabel(p.last_sync_source), device: platform === 'ios' ? 'iPhone' : platform === 'android' ? 'Android' : '-',
          platform: platform === 'ios' ? 'HealthKit' : platform === 'android' ? 'Health Connect' : '-',
          watch: /watch/i.test(JSON.stringify(act.sources ?? [])),
          todaySteps: num(act.steps_total), mealsToday: num(scBy.get(p.id)?.main_meal_count), flagged,
          recordModeReason: reasonBy.has(p.user_id) ? RECORD_REASON[reasonBy.get(p.user_id)!] ?? reasonBy.get(p.user_id)! : null,
        };
      });
    },
    async participantDays(pid): Promise<DayRow[]> {
      const [{ data: sc, error }, { data: acts }] = await Promise.all([
        sb.from('daily_scores').select('*').eq('participant_id', pid).order('local_date'),
        sb.from('daily_activity').select('local_date, steps_total').eq('participant_id', pid),
      ]);
      if (error) fail('일별 장부를 불러오지 못했어요', error);
      const scores = sc as Row[];
      const { data: revs } = scores.length
        ? await sb.from('score_revisions').select('daily_score_id, prev_s_d, reason, created_at').in('daily_score_id', scores.map((r) => r.id)).eq('reason', 'verdict').order('created_at')
        : { data: [] };
      const prevBy = new Map<string, number>();
      for (const r of (revs ?? []) as Row[]) if (!prevBy.has(r.daily_score_id)) prevBy.set(r.daily_score_id, num(r.prev_s_d)); // 가장 처음 값
      const stepsBy = new Map<string, number>(((acts ?? []) as Row[]).map((a) => [a.local_date, num(a.steps_total)]));
      return scores.map((r): DayRow => ({
        date: r.local_date, label: mdDate(r.local_date), steps: stepsBy.get(r.local_date) ?? 0,
        a: num(r.a_d), i: num(r.i_d), d: num(r.d_d), s: num(r.s_d), sBefore: prevBy.get(r.id) ?? null,
        check: !r.is_counted, provisional: !r.is_final, revised: prevBy.has(r.id),
        floorApplied: r.i_d != null && r.f_p != null && Number(r.i_d) < Number(r.f_p), underReview: Boolean(r.under_review),
      }));
    },
    async participantAction(pid, action: ParticipantAction, memo) {
      const cid = await challengeOfParticipant(pid);
      if (action === 'memo') {
        const { error } = await sb.from('participant_notes').upsert({ participant_id: pid, challenge_id: cid, operator_note: memo });
        if (error) fail('메모를 저장하지 못했어요', error);
      } else {
        const patch: Row =
          action === 'exclude' ? { status: 'excluded', rank_eligible: false }
          : action === 'kick' ? { status: 'kicked', rank_eligible: false, block_rejoin: true }
          : { block_rejoin: true };
        const { error } = await sb.from('participants').update(patch).eq('id', pid);
        if (error) fail('조치를 저장하지 못했어요', error);
      }
      await audit(cid, `participant_${action}`, { participant_id: pid, memo: action === 'memo' ? undefined : memo });
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
      const { data, error } = await sb.from('reviews')
        .select('*, participants(nickname, warning_count, baseline_median_steps, last_sync_source), appeals(text, created_at), review_reporters(reason)')
        .eq('challenge_id', challengeId).order('sla_due_at', { ascending: true, nullsFirst: false });
      if (error) fail('검토 큐를 불러오지 못했어요', error);
      const rows = data as Row[];
      const mealIds = rows.map((r) => r.target?.meal_id).filter(Boolean) as string[];
      const meals = new Map<string, Row>();
      if (mealIds.length) {
        const { data: ms } = await sb.from('meals').select('id, slot, local_date, title, ai_kcal, confirmed_kcal, photo_id').in('id', mealIds);
        for (const m of (ms ?? []) as Row[]) meals.set(m.id, m);
      }
      return Promise.all(rows.map(async (r): Promise<ReviewItem> => {
        const target = (r.target ?? {}) as Row;
        const meal = target.meal_id ? meals.get(target.meal_id) : undefined;
        const localDate: string = r.local_date ?? meal?.local_date ?? String(r.created_at).slice(0, 10);
        const appeal = Array.isArray(r.appeals) ? r.appeals[0] : r.appeals;
        const reporter = Array.isArray(r.review_reporters) ? r.review_reporters[0] : r.review_reporters;
        const type = r.type as ReviewType;
        const due = r.sla_due_at ?? new Date(Date.parse(r.created_at) + 72 * 3600e3).toISOString();
        return {
          id: r.id, shortId: `R-${String(r.id).slice(0, 4).toUpperCase()}`, type, label: REASON_LABEL_BY_TYPE[type] ?? type,
          participantId: r.participant_id, nickname: r.participants?.nickname ?? '-', localDate, dateLabel: mdDate(localDate),
          slot: (meal?.slot as Slot | undefined) ?? (target.slot as Slot | undefined) ?? null, status: r.status, verdict: r.verdict ?? null, reasonTemplate: (r.reason_template as ReasonTemplate | null) ?? null,
          slaDueAt: due, createdAt: r.created_at, appealText: appeal?.text ?? null, appealAt: appeal?.created_at ? mdTime(appeal.created_at) : null,
          reportText: type === 'report' ? (reporter?.reason ?? target.report_reason ?? null) : null, reportAt: type === 'report' ? mdTime(r.created_at) : null,
          warningCount: num(r.participants?.warning_count), evidence: await evidenceFor(r, meal),
          decidedAt: r.decided_at ? mdTime(r.decided_at) : null, decidedBy: r.decided_by ? '운영자' : null,
        };
      }));
    },
    async verdict(reviewId, verdict: Verdict, reason: ReasonTemplate | null, dryRun): Promise<VerdictImpact> {
      // apply_verdict_rpc 가 운영자 검사·점수 재계산·알림(N-06)·감사 로그까지 한 번에 처리한다(actor = 본인 고정).
      const { data, error } = await sb.rpc('apply_verdict_rpc', {
        p_review_id: reviewId, p_verdict: verdict, p_dry_run: dryRun, p_reason_template: reason,
      });
      if (error) fail(dryRun ? '점수 영향을 미리 계산하지 못했어요' : '판정을 저장하지 못했어요', error);
      const d = data as Row;
      if (!dryRun) notify();
      return {
        local_date: d.local_date, s_before: num(d.s_before), s_after: num(d.s_after), cumulative_before: num(d.cumulative_before), cumulative_after: num(d.cumulative_after),
        m_p: d.m_p != null ? num(d.m_p) : null, substitution: d.substitution ?? null, warning_count: num(d.warning_count),
        is_final: d.provisional === undefined ? undefined : !d.provisional,
      };
    },
    async auditLog(challengeId): Promise<AuditEntry[]> {
      const { data, error } = await sb.from('audit_logs').select('*').eq('challenge_id', challengeId).order('created_at', { ascending: false }).limit(30);
      if (error) return [];
      return (data as Row[]).map((a) => ({
        at: mdTime(a.created_at), by: a.actor_role === 'system' ? '시스템' : '운영자',
        text: `${a.action}${a.target && Object.keys(a.target).length ? ` · ${JSON.stringify(a.target)}` : ''}`,
      }));
    },
    completedReviewCount: (id) => count('reviews', (q) => q.eq('challenge_id', id).eq('status', 'decided')),

    async finalRanking(challengeId): Promise<FinalRanking> {
      const { data, error } = await sb.from('leaderboard_snapshots').select('*').eq('challenge_id', challengeId).eq('scope', 'cumulative').order('as_of', { ascending: false }).limit(5);
      if (error) fail('최종 순위를 불러오지 못했어요', error);
      const snaps = (data ?? []) as Row[];
      const snap = snaps.find((s) => s.is_final) ?? snaps[0];
      // 스냅샷 rows에는 확정 끼니 수가 없어 daily_scores에서 합산한다. 검토 중 행(aggregating)은 명단에서 뺀다.
      const all = ((snap?.rows ?? []) as Row[]).filter((r) => !r.aggregating && r.participant_id);
      const top = all.slice(0, 5);
      const meals = new Map<string, number>();
      let counted = 0;
      if (top.length) {
        const { data: sc } = await sb.from('daily_scores').select('participant_id, main_meal_count, local_date').in('participant_id', top.map((r) => r.participant_id)).eq('is_counted', true).eq('is_final', true);
        const days = new Set<string>();
        for (const r of (sc ?? []) as Row[]) { meals.set(r.participant_id, (meals.get(r.participant_id) ?? 0) + num(r.main_meal_count)); days.add(r.local_date); }
        counted = days.size;
      }
      const excluded = await count('participants', (q) => q.eq('challenge_id', challengeId).eq('rank_eligible', false));
      return {
        rows: top.map((r, i) => {
          const m = meals.get(r.participant_id) ?? 0, total = Math.max(1, counted * 3);
          return { rank: num(r.rank, i + 1), nickname: r.nickname, score: num(r.score), confirmedMeals: m, mealsTotal: total, fill: Math.round(m / total * 4) };
        }),
        total: all.length, hiddenExcluded: excluded, isFinal: Boolean(snap?.is_final), asOf: snap?.as_of ?? null,
      };
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

  async function evidenceFor(r: Row, meal: Row | undefined): Promise<ReviewEvidence> {
    const ev: ReviewEvidence = {};
    const pid: string = r.participant_id;
    const localDate: string = r.local_date ?? meal?.local_date;
    try {
      if (r.type === 'steps_spike' && localDate) {
        const { data } = await sb.from('daily_activity').select('local_date, steps_total, sources').eq('participant_id', pid).gte('local_date', addDays(localDate, -6)).lte('local_date', localDate).order('local_date');
        const rows = (data ?? []) as Row[];
        ev.steps7 = rows.map((x) => ({ label: mdDate(x.local_date), steps: num(x.steps_total) }));
        ev.stepsBaseline = r.participants?.baseline_median_steps ?? (rows.length ? median(rows.slice(0, 3).map((x) => num(x.steps_total))) : undefined);
        ev.stepsSource = sourceLabel(r.participants?.last_sync_source);
        const { count: sess } = await sb.from('activity_sessions').select('id', { count: 'exact', head: true }).eq('participant_id', pid).eq('local_date', localDate);
        ev.sessionNote = sess ? `세션 ${sess}건` : '없음 · 걸음만 동기화';
      }
      if (meal) {
        const { data: dsRow } = await sb.from('daily_scores').select('m_p').eq('participant_id', pid).eq('local_date', meal.local_date).maybeSingle();
        ev.ai = { title: meal.title ?? '', aiKcal: meal.ai_kcal != null ? num(meal.ai_kcal) : null, confirmedKcal: meal.confirmed_kcal != null ? num(meal.confirmed_kcal) : null, substituteKcal: dsRow?.m_p != null ? Math.ceil(num(dsRow.m_p)) : null };
        if (meal.photo_id) {
          const { data: ph } = await sb.from('photos').select('id, sha256, sha256_server').eq('id', meal.photo_id).maybeSingle();
          const hash = (ph?.sha256_server ?? ph?.sha256 ?? '') as string;
          const short = hash ? `${hash.slice(0, 4)} ${hash.slice(4, 8)} … ${hash.slice(-4)}` : '';
          if (r.type === 'dup_photo' && hash) {
            const { data: twin } = await sb.from('photos').select('id').or(`sha256.eq.${hash},sha256_server.eq.${hash}`).neq('id', meal.photo_id).limit(1);
            const twinMeal = twin?.[0] ? (await sb.from('meals').select('local_date, slot').eq('photo_id', twin[0].id).maybeSingle()).data : null;
            const lab = (m: Row | null, same: string) => (m ? `${mdDate(m.local_date)} ${SLOT_KO[m.slot as Slot]} · ${same}` : same);
            ev.photoPair = { hash: short, labelA: lab(twinMeal, '원본'), labelB: lab(meal, '같은 사진') };
          } else if (hash) {
            ev.photo = { hash: short, label: `${mdDate(meal.local_date)} ${SLOT_KO[meal.slot as Slot]}` };
          }
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
      const { data: ac } = await sb.from('daily_activity').select('participant_id, local_date, steps_total, steps_net_kcal, sessions_net_kcal, floors_kcal, a_capped').in('participant_id', ids);
      const actBy = new Map<string, Row>(((ac ?? []) as Row[]).map((a) => [`${a.participant_id}|${a.local_date}`, a]));
      for (const r of (sc ?? []) as Row[]) {
        const act = actBy.get(`${r.participant_id}|${r.local_date}`) ?? {};
        if (type === 'scores') records.push({ nickname: nick.get(r.participant_id), local_date: r.local_date, steps: num(act.steps_total), a_d: r.a_d, i_d: r.i_d, d_d: r.d_d, s_d: r.s_d, is_counted: r.is_counted });
        else records.push({ nickname: nick.get(r.participant_id), local_date: r.local_date, steps_total: num(act.steps_total), steps_net: act.steps_net_kcal, sessions_net: act.sessions_net_kcal, floors_bonus: act.floors_kcal, a_capped: act.a_capped });
      }
    } else {
      const { data: ms } = await sb.from('meals').select('participant_id, local_date, slot, status, confirmed_kcal').in('participant_id', ids).order('local_date');
      for (const m of (ms ?? []) as Row[]) records.push({ nickname: nick.get(m.participant_id), local_date: m.local_date, slot: m.slot, status: m.status, confirmed_kcal: m.confirmed_kcal });
    }
    return buildCsv(type, code, records);
  }

  return api;
}
