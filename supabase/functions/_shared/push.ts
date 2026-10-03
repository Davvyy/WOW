// 푸시 발송(FCM HTTP v1, APNs 는 FCM 경유). 키가 없으면 콘솔 로그(모의).
export interface PushMessage {
  token: string;
  title?: string | null;
  body: string;
  data?: Record<string, string>;
}
export interface PushSender {
  send(m: PushMessage): Promise<boolean>;
}

export class LogPushSender implements PushSender {
  sent: PushMessage[] = [];
  async send(m: PushMessage) {
    this.sent.push(m);
    console.log('[push:mock]', m.token.slice(0, 8), m.body);
    return true;
  }
}

/** Firebase 서비스 계정 키(JSON)에서 쓰는 필드 */
export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

export interface TokenSource {
  token(): Promise<string>;
}

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token';

function b64url(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** 서비스 계정 키로 서명한 OAuth JWT(RS256, 1시간). Google 토큰 엔드포인트에 보내 액세스 토큰과 바꾼다. */
export async function signServiceAccountJwt(sa: ServiceAccount, nowSec: number): Promise<string> {
  const enc = (v: unknown) => b64url(new TextEncoder().encode(JSON.stringify(v)));
  const unsigned = `${enc({ alg: 'RS256', typ: 'JWT' })}.${enc({
    iss: sa.client_email,
    scope: FCM_SCOPE,
    aud: sa.token_uri ?? DEFAULT_TOKEN_URI,
    iat: nowSec,
    exp: nowSec + 3600,
  })}`;
  const pem = sa.private_key.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned)));
  return `${unsigned}.${b64url(sig)}`;
}

/** 서비스 계정 액세스 토큰. 만료 1분 전까지 재사용하고 그 뒤 새로 받는다(정적 토큰은 1시간 뒤 만료돼 푸시가 끊긴다). */
export class GoogleTokenSource implements TokenSource {
  private cached: { token: string; expiresAt: number } | null = null;
  constructor(private sa: ServiceAccount, private fetchImpl: typeof fetch = fetch, private now: () => number = Date.now) {}

  async token(): Promise<string> {
    const t = this.now();
    if (this.cached && t < this.cached.expiresAt - 60_000) return this.cached.token;
    const assertion = await signServiceAccountJwt(this.sa, Math.floor(t / 1000));
    const res = await this.fetchImpl(this.sa.token_uri ?? DEFAULT_TOKEN_URI, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }).toString(),
    });
    if (!res.ok) throw new Error(`google token ${res.status}`);
    const j = await res.json();
    this.cached = { token: j.access_token, expiresAt: t + (j.expires_in ?? 3600) * 1000 };
    return this.cached.token;
  }
}

export class FcmPushSender implements PushSender {
  constructor(private projectId: string, private tokens: TokenSource, private fetchImpl: typeof fetch = fetch) {}
  async send(m: PushMessage) {
    let accessToken: string;
    try {
      accessToken = await this.tokens.token();
    } catch (e) {
      console.error('[push] FCM 액세스 토큰을 받지 못함', e);
      return false;
    }
    const res = await this.fetchImpl(`https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`, {
      method: 'POST',
      headers: { authorization: `Bearer ${accessToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        message: {
          token: m.token,
          notification: { title: m.title ?? undefined, body: m.body },
          data: m.data,
          // 분석 완료처럼 바로 봐야 하는 알림이 도즈 모드에서 늦지 않게
          android: { priority: 'HIGH' },
        },
      }),
    });
    return res.ok;
  }
}

// 함수 인스턴스가 살아 있는 동안 서비스 계정별 토큰을 재사용한다(selectPushSender 는 요청마다 불린다)
const tokenSources = new Map<string, GoogleTokenSource>();

/** FCM_SERVICE_ACCOUNT(서비스 계정 키 JSON 전체)가 있으면 FCM, 없거나 깨졌으면 콘솔 로그(모의) */
export function selectPushSender(env: (k: string) => string | undefined): PushSender {
  const raw = env('FCM_SERVICE_ACCOUNT');
  if (!raw) return new LogPushSender();
  let sa: ServiceAccount;
  try {
    sa = JSON.parse(raw);
  } catch {
    console.error('[push] FCM_SERVICE_ACCOUNT 가 JSON 이 아니라 모의 발송으로 대신함');
    return new LogPushSender();
  }
  if (!sa.project_id || !sa.client_email || !sa.private_key) {
    console.error('[push] FCM_SERVICE_ACCOUNT 에 project_id·client_email·private_key 가 없어 모의 발송으로 대신함');
    return new LogPushSender();
  }
  let src = tokenSources.get(sa.client_email);
  if (!src) tokenSources.set(sa.client_email, src = new GoogleTokenSource(sa));
  return new FcmPushSender(sa.project_id, src);
}

/** claim_due_notifications · claim_notification 이 돌려주는 행 */
export interface ClaimedNotification {
  id: string;
  type: string;
  title: string | null;
  body: string;
  payload: Record<string, unknown> | null;
  push_tokens: string[];
}

/** 앱이 읽는 데이터 필드: type · id(알림) + payload(예: N-04 meal_id). FCM data 는 문자열만 받는다. */
export function pushData(n: ClaimedNotification): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(n.payload ?? {})) {
    if (v === null || v === undefined) continue;
    out[k] = typeof v === 'string' ? v : JSON.stringify(v);
  }
  out.type = n.type;
  out.id = n.id;
  return out;
}

/** 집은 알림을 기기 토큰마다 보낸다. 보낸 건수를 돌려준다. */
export async function dispatch(rows: ClaimedNotification[], push: PushSender): Promise<number> {
  let sent = 0;
  for (const n of rows) {
    const data = pushData(n);
    for (const token of n.push_tokens) {
      if (await push.send({ token, title: n.title, body: n.body, data })) sent++;
    }
  }
  return sent;
}

/** claim_notification 만 부를 수 있으면 되는 최소 DB 모양(테스트에서 가짜로 대신) */
export interface ClaimRpc {
  rpc(fn: 'claim_notification', args: { p_id: string }): PromiseLike<{ data: unknown; error: unknown }>;
}

/**
 * transactional 알림(N-04·N-06)을 워커 주기(1~5분)를 기다리지 않고 바로 보낸다.
 * 한 건씩 집으므로(claim_notification) 워커와 겹쳐도 두 번 가지 않고, 토큰 없음·권한 미허용이면 no_push 로 남는다.
 */
export async function sendNow(db: ClaimRpc, ids: string[], push: PushSender): Promise<number> {
  let sent = 0;
  for (const id of ids) {
    const { data, error } = await db.rpc('claim_notification', { p_id: id });
    if (error) continue; // 남은 건 워커가 보낸다
    sent += await dispatch((data ?? []) as ClaimedNotification[], push);
  }
  return sent;
}
