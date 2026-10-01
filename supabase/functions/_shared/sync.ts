// 활동 배치 검증(05 §5). kcal 은 받지 않는다: 순위용 kcal 은 서버 activity_kcal 만 계산.
// platform_active_kcal 은 P8 참고값으로만 저장. 수동 입력 걸음은 steps_manual 로 분리해 차감.
import { HttpError } from './http.ts';

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const SESSION_TYPES = new Set(['running', 'stair', 'walking']);
const FORBIDDEN_KEYS = ['kcal', 'active_kcal', 'calories', 'steps_net_kcal', 'a_d', 's_d'];

export interface SyncBatch {
  client_batch_id: string;
  tz?: string;
  days: SyncDay[];
}
export interface SyncDay {
  local_date: string;
  steps_total: number;
  steps_manual?: number | null;
  floors?: number | null;
  distance_m?: number | null;
  platform_active_kcal?: number | null;
  has_manual_source?: boolean;
  sources?: { origin: string; method?: string; steps?: number }[];
  sessions?: {
    platform_uid: string;
    type: 'running' | 'stair' | 'walking';
    start: string;
    end: string;
    distance_m?: number | null;
    steps_in_range?: number;
    origin?: string;
    method?: string;
  }[];
}

const isInt = (v: unknown) => Number.isInteger(v) && (v as number) >= 0;

export function validateSyncBatch(b: unknown): SyncBatch {
  const x = b as Record<string, unknown>;
  if (!x || typeof x !== 'object') throw new HttpError(422, 'body must be object');
  if (typeof x.client_batch_id !== 'string') throw new HttpError(422, 'client_batch_id required');
  if (x.tz !== undefined && x.tz !== 'Asia/Seoul') throw new HttpError(422, 'tz must be Asia/Seoul');
  if (!Array.isArray(x.days) || x.days.length === 0 || x.days.length > 3) throw new HttpError(422, 'days: 1~3일(D, D−1, D−2)');
  for (const d of x.days as Record<string, unknown>[]) {
    for (const k of FORBIDDEN_KEYS) if (k in d) throw new HttpError(422, `${k}: kcal 은 서버가 계산해요`);
    if (typeof d.local_date !== 'string' || !DATE.test(d.local_date)) throw new HttpError(422, 'local_date YYYY-MM-DD');
    if (!isInt(d.steps_total)) throw new HttpError(422, 'steps_total 정수 ≥0');
    if (d.steps_manual != null && !isInt(d.steps_manual)) throw new HttpError(422, 'steps_manual 정수 ≥0');
    if (d.steps_manual != null && (d.steps_manual as number) > (d.steps_total as number)) throw new HttpError(422, 'steps_manual > steps_total');
    if (d.floors != null && !isInt(d.floors)) throw new HttpError(422, 'floors 정수 ≥0');
    for (const s of (d.sessions as Record<string, unknown>[] | undefined) ?? []) {
      for (const k of FORBIDDEN_KEYS) if (k in s) throw new HttpError(422, `session.${k}: kcal 은 서버가 계산해요`);
      if (typeof s.platform_uid !== 'string' || !s.platform_uid) throw new HttpError(422, 'session.platform_uid');
      if (!SESSION_TYPES.has(s.type as string)) throw new HttpError(422, 'session.type running|stair|walking');
      const st = Date.parse(s.start as string), en = Date.parse(s.end as string);
      if (!Number.isFinite(st) || !Number.isFinite(en) || en <= st) throw new HttpError(422, 'session.start/end');
    }
  }
  return x as unknown as SyncBatch;
}
