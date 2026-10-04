import { assertEquals, assertRejects } from '@std/assert';
import { createMealFlow, deleteAccountFlow, deleteMealFlow, mealIdOf } from './flows.ts';
import { HttpError } from './http.ts';
import { imageSize, sha256Bytes } from './image.ts';

// 최소 JPEG: SOI, APP0(len 4), SOF0(1568×1176), EOI
function jpeg(w: number, h: number): Uint8Array {
  return new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 0x03,
    0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xd9]);
}
function png(w: number, h: number): Uint8Array {
  const b = new Uint8Array(24);
  b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  new DataView(b.buffer).setUint32(16, w); new DataView(b.buffer).setUint32(20, h);
  return b;
}

Deno.test('이미지 크기: JPEG SOF·PNG IHDR', () => {
  assertEquals(imageSize(jpeg(1568, 1176)), { width: 1568, height: 1176, type: 'jpeg' });
  assertEquals(imageSize(png(1000, 800)), { width: 1000, height: 800, type: 'png' });
  assertEquals(imageSize(new Uint8Array([1, 2, 3])), null);
});

Deno.test('SHA-256 hex', async () => {
  assertEquals(await sha256Bytes(new TextEncoder().encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

function mealDeps(over: Partial<Parameters<typeof createMealFlow>[0]> = {}) {
  const calls: string[] = [];
  const img = jpeg(1568, 1176);
  const deps = {
    photoPath: () => Promise.resolve('c/p/x.jpg'),
    download: () => Promise.resolve(img),
    verifyPhoto: (m: { sha256: string; bytes: number; width: number }) => { calls.push(`verify:${m.bytes}:${m.width}`); return Promise.resolve({ verified: true }); },
    createMeal: () => { calls.push('create'); return Promise.resolve({ meal_id: 'm1', analyze: true, slot: 'lunch' }); },
    triggerAnalyze: (id: string) => { calls.push(`analyze:${id}`); return Promise.resolve(); },
    ...over,
  };
  return { deps, calls };
}

Deno.test('끼니 생성: 서버가 잰 값으로 재검증 → 생성 → 분석 트리거', async () => {
  const { deps, calls } = mealDeps();
  const r = await createMealFlow(deps, { photo_id: 'p1' });
  assertEquals(r.meal_id, 'm1');
  assertEquals(calls, [`verify:${jpeg(1568, 1176).length}:1568`, 'create', 'analyze:m1']);
});

Deno.test('끼니 생성: 객체 없음 422, 재검증 불일치 422, 분석 없음(미동의)', async () => {
  const e1 = await assertRejects(() => createMealFlow(mealDeps({ download: () => Promise.resolve(null) }).deps, { photo_id: 'p1' }), HttpError);
  assertEquals(e1.status, 422);
  const e2 = await assertRejects(() => createMealFlow(mealDeps({ verifyPhoto: () => Promise.resolve({ verified: false }) }).deps, { photo_id: 'p1' }), HttpError);
  assertEquals(e2.status, 422);
  const { deps, calls } = mealDeps({ createMeal: () => Promise.resolve({ meal_id: 'm2', analyze: false }) });
  await createMealFlow(deps, { photo_id: 'p1' });
  assertEquals(calls.includes('analyze:m2'), false);
});

Deno.test('끼니 생성: 고른 끼니(아침·점심·저녁·간식)를 넘기고, 그 밖의 값은 무시(D58)', async () => {
  const seen: [string, boolean, string | null][] = [];
  const { deps } = mealDeps({
    createMeal: (photoId: string, queued: boolean, slot: string | null) => {
      seen.push([photoId, queued, slot]);
      return Promise.resolve({ meal_id: 'm3', analyze: false, slot: slot ?? 'breakfast' });
    },
  });
  const r = await createMealFlow(deps, { photo_id: 'p1', queued: true, slot: 'snack' });
  assertEquals(r.slot, 'snack');
  await createMealFlow(deps, { photo_id: 'p2' });
  await createMealFlow(deps, { photo_id: 'p3', slot: 'dinner' });
  await createMealFlow(deps, { photo_id: 'p4', slot: true });
  await createMealFlow(deps, { photo_id: 'p5', slot: 'brunch' });
  assertEquals(seen, [['p1', true, 'snack'], ['p2', false, null], ['p3', false, 'dinner'], ['p4', false, null], ['p5', false, null]]);
});

Deno.test('계정 삭제: 확인 문구, DB → Storage(100개 단위) → 로그인 차단 순서', async () => {
  const order: string[] = [];
  const paths = Array.from({ length: 150 }, (_, i) => `c/p/${i}.jpg`);
  const deps = {
    deleteRows: () => { order.push('db'); return Promise.resolve({ storage_paths: paths, participants: 1, deleted: { meals: 24 } }); },
    removeObjects: (p: string[]) => { order.push(`storage:${p.length}`); return Promise.resolve(); },
    disableAuthUser: () => { order.push('auth'); return Promise.resolve(); },
  };
  const e = await assertRejects(() => deleteAccountFlow(deps, { confirm: '네' }), HttpError);
  assertEquals([e.status, order.length], [422, 0]);
  const r = await deleteAccountFlow(deps, { confirm: '삭제' });
  assertEquals(order, ['db', 'storage:100', 'storage:50', 'auth']);
  assertEquals(r.photos_removed, 150);
});

Deno.test('끼니 삭제: meal_id 가 없거나 UUID 가 아니면 422', () => {
  for (const body of [{}, { meal_id: 3 }, { meal_id: 'abc' }, null]) {
    const e = (() => { try { mealIdOf(body); } catch (err) { return err; } })();
    assertEquals(e instanceof HttpError && e.status, 422);
  }
  assertEquals(mealIdOf({ meal_id: '6F1C2E0A-1b2c-4d3e-8f9a-0b1c2d3e4f5a' }), '6F1C2E0A-1b2c-4d3e-8f9a-0b1c2d3e4f5a');
});

Deno.test('끼니 삭제: DB 다음 purge_path 만 Storage 에서 지우고 계약 본문만 돌려준다', async () => {
  const order: string[] = [];
  const row = { meal_id: 'm1', deleted: 2, local_date: '2026-10-13', slot: 'lunch' };
  const deps = (purge: string | null) => ({
    deleteMeal: (id: string) => { order.push(`db:${id}`); return Promise.resolve({ ...row, purge_path: purge }); },
    removeObjects: (p: string[]) => { order.push(`storage:${p.join(',')}`); return Promise.resolve([] as string[]); },
    unmarkPurged: (p: string[]) => { order.push(`unmark:${p.join(',')}`); return Promise.resolve(); },
  });
  assertEquals(await deleteMealFlow(deps('c/p/x.jpg'), 'm1'), row);
  assertEquals(order, ['db:m1', 'storage:c/p/x.jpg']);
  order.length = 0;
  assertEquals(await deleteMealFlow(deps(null), 'm1'), row);
  assertEquals(order, ['db:m1']);
});

Deno.test('끼니 삭제: Storage 삭제가 실패하면 파기 표시를 되돌리고 200 본문에 photo_retry', async () => {
  const row = { meal_id: 'm1', deleted: 1, local_date: '2026-10-13', slot: 'snack' };
  for (const removeObjects of [
    () => Promise.resolve(['c/p/y.jpg']),
    () => Promise.reject(new HttpError(502, 'storage remove: boom')),
  ]) {
    const unmarked: string[][] = [];
    const deps = {
      deleteMeal: () => Promise.resolve({ ...row, purge_path: 'c/p/y.jpg' }),
      removeObjects,
      unmarkPurged: (p: string[]) => { unmarked.push(p); return Promise.resolve(); },
    };
    assertEquals(await deleteMealFlow(deps, 'm1'), { ...row, photo_retry: true });
    assertEquals(unmarked, [['c/p/y.jpg']]);
  }
});
