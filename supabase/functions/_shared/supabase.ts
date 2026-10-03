// Supabase 클라이언트: service_role(배치·RPC 쓰기)과 호출자 JWT(RLS 적용) 두 가지.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { HttpError } from './http.ts';
import type { IdempotencyStore, StoredResponse } from './idempotency.ts';
import { selectPushSender, sendNow } from './push.ts';

export function env(k: string): string | undefined {
  return Deno.env.get(k);
}

export function serviceClient(): SupabaseClient {
  const url = env('SUPABASE_URL'), key = env('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new HttpError(500, 'SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 미설정');
  return createClient(url, key, { auth: { persistSession: false } });
}

export function userClient(req: Request): SupabaseClient {
  const url = env('SUPABASE_URL'), anon = env('SUPABASE_ANON_KEY');
  if (!url || !anon) throw new HttpError(500, 'SUPABASE_URL / SUPABASE_ANON_KEY 미설정');
  return createClient(url, anon, {
    auth: { persistSession: false },
    // 키는 'Authorization' 이어야 한다: supabase-js 가 인증 요청 헤더를 { Authorization: Bearer <anon>, ...global } 로 합치므로
    // 소문자 키면 기본값을 덮지 못하고 'Bearer <anon>, Bearer <user>' 로 합쳐져 getUser() 가 401 이 된다.
    global: { headers: { Authorization: req.headers.get('authorization') ?? '' } },
  });
}

export async function requireUser(req: Request): Promise<{ id: string; client: SupabaseClient }> {
  const client = userClient(req);
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) throw new HttpError(401, 'login required');
  return { id: data.user.id, client };
}

export class PgIdempotencyStore implements IdempotencyStore {
  constructor(private db: SupabaseClient) {}
  async get(userId: string, key: string): Promise<StoredResponse | null> {
    const { data } = await this.db.from('idempotency_keys').select('request_hash, status_code, response')
      .eq('user_id', userId).eq('key', key).maybeSingle();
    return data as StoredResponse | null;
  }
  async put(userId: string, key: string, endpoint: string, v: StoredResponse) {
    await this.db.from('idempotency_keys').insert({ user_id: userId, key, endpoint, ...v });
  }
}

/**
 * 방금 큐에 들어간 알림을 워커(1~5분)를 기다리지 않고 보낸다: N-05(검토 안내)·N-06(판정 결과).
 * [match] 는 user_id 또는 payload.review_id. 예약 시각이 아직이면(22~08시 생성 N-05) claim 이 건너뛰고 워커가 08:00 에 보낸다.
 * 보내기에서 막혀도 요청은 성공으로 두고 워커가 이어서 보낸다.
 */
export async function sendPendingNow(db: SupabaseClient, type: 'N-05' | 'N-06', match: { user_id?: string; review_id?: string }) {
  try {
    let q = db.from('notifications').select('id').eq('type', type).is('sent_at', null).is('skipped_reason', null)
      .lte('scheduled_at', new Date().toISOString());
    if (match.user_id) q = q.eq('user_id', match.user_id);
    if (match.review_id) q = q.contains('payload', { review_id: match.review_id });
    const { data } = await q;
    return await sendNow(db, (data ?? []).map((n: { id: string }) => n.id), selectPushSender(env));
  } catch (e) {
    console.warn('sendPendingNow', type, e);
    return 0;
  }
}
