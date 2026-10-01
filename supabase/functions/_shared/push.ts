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

export class FcmPushSender implements PushSender {
  constructor(private projectId: string, private accessToken: string, private fetchImpl: typeof fetch = fetch) {}
  async send(m: PushMessage) {
    const res = await this.fetchImpl(`https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`, {
      method: 'POST',
      headers: { authorization: `Bearer ${this.accessToken}`, 'content-type': 'application/json' },
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

export function selectPushSender(env: (k: string) => string | undefined): PushSender {
  const p = env('FCM_PROJECT_ID'), t = env('FCM_ACCESS_TOKEN');
  return p && t ? new FcmPushSender(p, t) : new LogPushSender();
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
