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
