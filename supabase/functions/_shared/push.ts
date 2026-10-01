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
      body: JSON.stringify({ message: { token: m.token, notification: { title: m.title ?? undefined, body: m.body }, data: m.data } }),
    });
    return res.ok;
  }
}

export function selectPushSender(env: (k: string) => string | undefined): PushSender {
  const p = env('FCM_PROJECT_ID'), t = env('FCM_ACCESS_TOKEN');
  return p && t ? new FcmPushSender(p, t) : new LogPushSender();
}
