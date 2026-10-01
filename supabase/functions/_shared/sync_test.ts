import { assertEquals, assertRejects, assertThrows } from '@std/assert';
import { validateSyncBatch } from './sync.ts';
import { MemoryStore, withIdempotency } from './idempotency.ts';
import { fromDbError, HttpError } from './http.ts';
import { LogPushSender, selectPushSender } from './push.ts';

const good = {
  client_batch_id: '6f1c2b1e-1111-4222-8333-944455556666', tz: 'Asia/Seoul',
  days: [{ local_date: '2026-10-13', steps_total: 9000, steps_manual: 0, floors: 12, platform_active_kcal: 310,
    sources: [{ origin: 'com.sec.android.app.shealth', method: 'AUTOMATICALLY_RECORDED' }],
    sessions: [{ platform_uid: 'hc:1', type: 'running', start: '2026-10-13T07:00:00+09:00', end: '2026-10-13T07:30:00+09:00', distance_m: 4500, steps_in_range: 4500 }] }],
};

Deno.test('배치 검증: 정상', () => assertEquals(validateSyncBatch(good).days.length, 1));
Deno.test('배치 검증: kcal 필드 거부(순위 kcal 은 서버 계산)', () => {
  assertThrows(() => validateSyncBatch({ ...good, days: [{ ...good.days[0], kcal: 500 }] }), HttpError);
  assertThrows(() => validateSyncBatch({ ...good, days: [{ ...good.days[0], sessions: [{ ...good.days[0].sessions[0], calories: 300 }] }] }), HttpError);
});
Deno.test('배치 검증: 4일 이상·음수·수동>합계·시간대 거부', () => {
  assertThrows(() => validateSyncBatch({ ...good, days: [good.days[0], good.days[0], good.days[0], good.days[0]] }));
  assertThrows(() => validateSyncBatch({ ...good, days: [{ ...good.days[0], steps_total: -1 }] }));
  assertThrows(() => validateSyncBatch({ ...good, days: [{ ...good.days[0], steps_manual: 9001 }] }));
  assertThrows(() => validateSyncBatch({ ...good, tz: 'UTC' }));
});

Deno.test('멱등: 같은 키·같은 본문 → 저장 응답, 다른 본문 → 409', async () => {
  const store = new MemoryStore();
  let runs = 0;
  const run = () => { runs++; return Promise.resolve({ status: 200, body: { n: runs } }); };
  const key = '0f8fad5b-d9cb-469f-a165-70867728950e';
  const a = await withIdempotency(store, 'u', key, 'verdict', { x: 1 }, run);
  const b = await withIdempotency(store, 'u', key, 'verdict', { x: 1 }, run);
  assertEquals([a.replayed, b.replayed, runs, b.body], [false, true, 1, { n: 1 }]);
  const e = await assertRejects(() => withIdempotency(store, 'u', key, 'verdict', { x: 2 }, run), HttpError);
  assertEquals(e.status, 409);
  await assertRejects(() => withIdempotency(store, 'u', null, 'verdict', {}, run), HttpError);
});

Deno.test('DB 오류 매핑: PT412→412, 42501→403', () => {
  assertEquals(fromDbError({ code: 'PT412', message: 'version mismatch' }).status, 412);
  assertEquals(fromDbError({ code: 'PT422', message: '미결 2건' }).status, 422);
  assertEquals(fromDbError({ code: '42501' }).status, 403);
});

Deno.test('푸시: 키 없으면 모의 발송', async () => {
  const s = selectPushSender(() => undefined);
  assertEquals(s instanceof LogPushSender, true);
  assertEquals(await s.send({ token: 'abcdefghij', body: '어제 28.8점, 누적 4위' }), true);
});
