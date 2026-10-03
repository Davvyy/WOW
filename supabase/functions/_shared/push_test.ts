import { assertEquals } from '@std/assert';
import {
  dispatch,
  FcmPushSender,
  GoogleTokenSource,
  LogPushSender,
  pushData,
  selectPushSender,
  sendNow,
  type ServiceAccount,
  signServiceAccountJwt,
} from './push.ts';

/** 테스트용 서비스 계정: 진짜 RSA 키로 만들어 서명을 실제로 검증한다 */
async function testServiceAccount(email = 'push@test.iam.gserviceaccount.com') {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  const b64 = btoa(String.fromCharCode(...der)).replace(/(.{64})/g, '$1\n');
  const sa: ServiceAccount = {
    project_id: 'challory-test',
    client_email: email,
    private_key: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`,
    token_uri: 'https://oauth2.googleapis.com/token',
  };
  return { sa, publicKey: pair.publicKey };
}

function b64urlDecode(s: string): Uint8Array<ArrayBuffer> {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

Deno.test('서비스 계정 JWT: RS256 서명이 공개키로 검증되고 FCM 범위·1시간 만료를 담는다', async () => {
  const { sa, publicKey } = await testServiceAccount();
  const jwt = await signServiceAccountJwt(sa, 1_800_000_000);
  const [h, p, s] = jwt.split('.');
  assertEquals(JSON.parse(new TextDecoder().decode(b64urlDecode(h))), { alg: 'RS256', typ: 'JWT' });
  assertEquals(JSON.parse(new TextDecoder().decode(b64urlDecode(p))), {
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: 1_800_000_000,
    exp: 1_800_003_600,
  });
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', publicKey, b64urlDecode(s), new TextEncoder().encode(`${h}.${p}`));
  assertEquals(ok, true);
});

Deno.test('액세스 토큰: 만료 1분 전까지 재사용하고 그 뒤 새로 받는다', async () => {
  const { sa } = await testServiceAccount();
  let now = 1_800_000_000_000;
  const requests: URLSearchParams[] = [];
  const fake = ((_u: string, init: RequestInit) => {
    requests.push(new URLSearchParams(init.body as string));
    return Promise.resolve(Response.json({ access_token: `a${requests.length}`, expires_in: 3600 }));
  }) as unknown as typeof fetch;
  const src = new GoogleTokenSource(sa, fake, () => now);

  assertEquals(await src.token(), 'a1');
  now += 3_500_000; // 58분 20초 뒤: 아직 재사용
  assertEquals(await src.token(), 'a1');
  now += 50_000; // 59분 10초 뒤: 만료 1분 안쪽이라 새로 받음
  assertEquals(await src.token(), 'a2');
  assertEquals(requests.length, 2);
  assertEquals(requests[0].get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  assertEquals(requests[0].get('assertion')?.split('.').length, 3);
});

Deno.test('FCM 발송: 서비스 계정 토큰을 Bearer 로 싣고, 토큰을 못 받으면 실패로 돌려준다', async () => {
  const urls: string[] = [];
  const auths: (string | null)[] = [];
  const fake = ((u: string, init: RequestInit) => {
    urls.push(u);
    auths.push(new Headers(init.headers).get('authorization'));
    return Promise.resolve(new Response('{}', { status: 200 }));
  }) as unknown as typeof fetch;
  const ok = await new FcmPushSender('challory-test', { token: () => Promise.resolve('a1') }, fake).send({ token: 'tok', body: 'b' });
  assertEquals(ok, true);
  assertEquals(urls[0], 'https://fcm.googleapis.com/v1/projects/challory-test/messages:send');
  assertEquals(auths[0], 'Bearer a1');

  const failed = await new FcmPushSender('challory-test', { token: () => Promise.reject(new Error('token 400')) }, fake)
    .send({ token: 'tok', body: 'b' });
  assertEquals(failed, false);
  assertEquals(urls.length, 1);
});

Deno.test('푸시 선택: FCM_SERVICE_ACCOUNT 가 있으면 FCM, JSON 이 깨졌거나 없으면 모의', async () => {
  const { sa } = await testServiceAccount('select@test.iam.gserviceaccount.com');
  const env = (v: string | undefined) => (k: string) => (k === 'FCM_SERVICE_ACCOUNT' ? v : undefined);
  assertEquals(selectPushSender(env(JSON.stringify(sa))) instanceof FcmPushSender, true);
  assertEquals(selectPushSender(env('{not json')) instanceof LogPushSender, true);
  assertEquals(selectPushSender(env(undefined)) instanceof LogPushSender, true);
});

Deno.test('N-04 데이터: meal_id·slot 이 문자열로 실리고 type·id 는 덮어쓰지 못함', () => {
  const d = pushData({ id: 'n1', type: 'N-04', title: '분석 완료', body: '점심 분석이 끝났어요', payload: { meal_id: 'm1', slot: 'lunch', n: 3, type: 'x' }, push_tokens: [] });
  assertEquals(d, { meal_id: 'm1', slot: 'lunch', n: '3', type: 'N-04', id: 'n1' });
});

Deno.test('기기 토큰마다 보냄', async () => {
  const push = new LogPushSender();
  const sent = await dispatch([{ id: 'n1', type: 'N-04', title: null, body: 'b', payload: { meal_id: 'm1' }, push_tokens: ['a', 'b'] }], push);
  assertEquals(sent, 2);
  assertEquals(push.sent.map((m) => m.data?.meal_id), ['m1', 'm1']);
});

Deno.test('FCM v1 요청: data 와 안드로이드 높은 우선순위', async () => {
  let body: Record<string, unknown> = {};
  const fake = ((_u: string, init: RequestInit) => {
    body = JSON.parse(init.body as string);
    return Promise.resolve(new Response('{}', { status: 200 }));
  }) as unknown as typeof fetch;
  const ok = await new FcmPushSender('p', { token: () => Promise.resolve('t') }, fake)
    .send({ token: 'tok', title: '분석 완료', body: 'b', data: { type: 'N-04', meal_id: 'm1' } });
  assertEquals(ok, true);
  // deno-lint-ignore no-explicit-any
  const m = (body as any).message;
  assertEquals(m.data, { type: 'N-04', meal_id: 'm1' });
  assertEquals(m.android, { priority: 'HIGH' });
});

Deno.test('바로 보내기: 한 건씩 집고, 집기 오류는 건너뜀(워커가 이어서)', async () => {
  const push = new LogPushSender();
  const claimed: string[] = [];
  const db = {
    rpc(_fn: 'claim_notification', { p_id }: { p_id: string }) {
      claimed.push(p_id);
      if (p_id === 'bad') return Promise.resolve({ data: null, error: { message: 'x' } });
      return Promise.resolve({
        data: [{ id: p_id, type: 'N-06', title: '판정 결과', body: '10.12 저녁 기록은 승인됐어요', payload: { review_id: 'r1', verdict: 'approve' }, push_tokens: ['t'] }],
        error: null,
      });
    },
  };
  const sent = await sendNow(db, ['n1', 'bad'], push);
  assertEquals(claimed, ['n1', 'bad']);
  assertEquals(sent, 1);
  assertEquals(push.sent[0].data, { review_id: 'r1', verdict: 'approve', type: 'N-06', id: 'n1' });
});
