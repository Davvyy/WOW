import { assertEquals } from '@std/assert';
import { dispatch, FcmPushSender, LogPushSender, pushData } from './push.ts';

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
  const ok = await new FcmPushSender('p', 't', fake).send({ token: 'tok', title: '분석 완료', body: 'b', data: { type: 'N-04', meal_id: 'm1' } });
  assertEquals(ok, true);
  // deno-lint-ignore no-explicit-any
  const m = (body as any).message;
  assertEquals(m.data, { type: 'N-04', meal_id: 'm1' });
  assertEquals(m.android, { priority: 'HIGH' });
});
