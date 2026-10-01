// 멱등 규약(05 §4): 모든 F: 쓰기는 Idempotency-Key 필수. 같은 키·같은 본문 → 저장된 응답(200),
// 같은 키·다른 본문 → 409. 저장소는 idempotency_keys 테이블(운영) 또는 메모리(테스트).
import { HttpError } from './http.ts';

export interface StoredResponse {
  request_hash: string;
  status_code: number;
  response: unknown;
}

export interface IdempotencyStore {
  get(userId: string, key: string): Promise<StoredResponse | null>;
  put(userId: string, key: string, endpoint: string, value: StoredResponse): Promise<void>;
}

export class MemoryStore implements IdempotencyStore {
  map = new Map<string, StoredResponse>();
  async get(u: string, k: string) {
    return this.map.get(`${u}:${k}`) ?? null;
  }
  async put(u: string, k: string, _e: string, v: StoredResponse) {
    this.map.set(`${u}:${k}`, v);
  }
}

export async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function withIdempotency(
  store: IdempotencyStore,
  userId: string,
  key: string | null,
  endpoint: string,
  body: unknown,
  run: () => Promise<{ status: number; body: unknown }>,
): Promise<{ status: number; body: unknown; replayed: boolean }> {
  if (!key || !UUID.test(key)) throw new HttpError(400, 'Idempotency-Key(UUID) 헤더가 필요해요');
  const hash = await sha256Hex(JSON.stringify(body ?? null));
  const prev = await store.get(userId, key);
  if (prev) {
    if (prev.request_hash !== hash) throw new HttpError(409, '같은 Idempotency-Key 에 다른 요청 본문');
    return { status: 200, body: prev.response, replayed: true };
  }
  const out = await run();
  if (out.status < 500) await store.put(userId, key, endpoint, { request_hash: hash, status_code: out.status, response: out.body });
  return { ...out, replayed: false };
}
