import { assertEquals, assertRejects } from '@std/assert';
import { HttpError } from './http.ts';
import { removeInBatches, type RemovableStorage } from './storage.ts';

function fakeStorage(failOnCall = -1): RemovableStorage & { calls: string[][] } {
  const calls: string[][] = [];
  return {
    calls,
    remove(paths: string[]) {
      calls.push(paths);
      return Promise.resolve({ error: calls.length - 1 === failOnCall ? { message: 'boom' } : null });
    },
  };
}

const paths = (n: number) => Array.from({ length: n }, (_, i) => `p/${i}.jpg`);

Deno.test('removeInBatches: 100개씩 나눠 순서대로 지운다', async () => {
  const s = fakeStorage();
  await removeInBatches(s, paths(250));
  assertEquals(s.calls.map((c) => c.length), [100, 100, 50]);
  assertEquals(s.calls.flat(), paths(250));
});

Deno.test('removeInBatches: 경로가 없으면 호출하지 않는다', async () => {
  const s = fakeStorage();
  await removeInBatches(s, []);
  assertEquals(s.calls.length, 0);
});

Deno.test('removeInBatches: 정확히 100개면 한 번', async () => {
  const s = fakeStorage();
  await removeInBatches(s, paths(100));
  assertEquals(s.calls.map((c) => c.length), [100]);
});

Deno.test('removeInBatches: 삭제 오류는 502 로 멈춘다', async () => {
  const s = fakeStorage(1);
  const e = await assertRejects(() => removeInBatches(s, paths(250)), HttpError, 'storage remove: boom');
  assertEquals(e.status, 502);
  assertEquals(s.calls.length, 2);
});

Deno.test('removeInBatches(수집 모드): 실패한 배치를 건너뛰고 끝까지 돌며 실패 경로를 돌려준다', async () => {
  const s = fakeStorage(1);
  const failed = await removeInBatches(s, paths(250), 100, { collectFailures: true });
  assertEquals(s.calls.map((c) => c.length), [100, 100, 50]);
  assertEquals(failed, paths(250).slice(100, 200));
});

Deno.test('removeInBatches(수집 모드): 예외를 던지는 배치도 실패로 모은다, 모두 성공하면 빈 배열', async () => {
  let n = 0;
  const throwing: RemovableStorage = {
    remove(p: string[]) {
      n++;
      return n === 1 ? Promise.reject(new Error('network')) : Promise.resolve({ error: null });
    },
  };
  assertEquals(await removeInBatches(throwing, paths(150), 100, { collectFailures: true }), paths(100));
  assertEquals(await removeInBatches(fakeStorage(), paths(10), 100, { collectFailures: true }), []);
});

Deno.test('removeInBatches(기본 모드): 첫 오류에서 502 로 멈추는 동작 그대로', async () => {
  const s = fakeStorage(0);
  const e = await assertRejects(() => removeInBatches(s, paths(150)), HttpError);
  assertEquals([e.status, s.calls.length], [502, 1]);
});
