// Supabase 클라이언트: service_role(배치·RPC 쓰기)과 호출자 JWT(RLS 적용) 두 가지.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { HttpError } from './http.ts';
import type { IdempotencyStore, StoredResponse } from './idempotency.ts';

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
    global: { headers: { authorization: req.headers.get('authorization') ?? '' } },
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
