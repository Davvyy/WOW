import { assertEquals } from '@std/assert';
import { type MealPhotoRow, PHOTO_URL_TTL_S, photoUrlResponse, type PhotoUrlDeps } from './photo_url.ts';
import { HttpError } from './http.ts';
import { requireUser } from './supabase.ts';

const ME = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const MEAL = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const PATH = 'c1/p1/ph1.jpg';

function fakeDeps(row: MealPhotoRow | null, over: Partial<PhotoUrlDeps> = {}) {
  const calls: string[] = [];
  const deps: PhotoUrlDeps = {
    requireUser: (req) => {
      const auth = req.headers.get('authorization');
      if (auth !== 'Bearer ME') return Promise.reject(new HttpError(401, 'login required'));
      return Promise.resolve({ id: ME });
    },
    findMealPhoto: (id) => {
      calls.push(`find:${id}`);
      return Promise.resolve(row);
    },
    signDownload: (path, ttl) => {
      calls.push(`sign:${path}:${ttl}`);
      return Promise.resolve(`https://example.supabase.co/storage/v1/object/sign/meal-photos/${path}?token=t`);
    },
    ...over,
  };
  return { deps, calls };
}

function post(body: unknown, auth: string | null = 'Bearer ME', method = 'POST'): Request {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (auth) headers.authorization = auth;
  return new Request('https://fn.example/photo-url', { method, headers, body: method === 'POST' ? JSON.stringify(body) : undefined });
}

const mine: MealPhotoRow = { owner_user_id: ME, storage_path: PATH, purged_at: null };

Deno.test('photo-url: 내 끼니 사진이면 300초 서명 다운로드 URL', async () => {
  const { deps, calls } = fakeDeps(mine);
  const res = await photoUrlResponse(post({ meal_id: MEAL }), deps);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.meal_id, MEAL);
  assertEquals(body.expires_in, 300);
  assertEquals(body.signed_url, `https://example.supabase.co/storage/v1/object/sign/meal-photos/${PATH}?token=t`);
  assertEquals(calls, [`find:${MEAL}`, `sign:${PATH}:${PHOTO_URL_TTL_S}`]);
  assertEquals(PHOTO_URL_TTL_S, 300);
});

Deno.test('photo-url: 남의 끼니는 404 이고 서명하지 않는다(있는지 알리지 않음)', async () => {
  const { deps, calls } = fakeDeps({ ...mine, owner_user_id: OTHER });
  const res = await photoUrlResponse(post({ meal_id: MEAL }), deps);
  assertEquals(res.status, 404);
  assertEquals((await res.json()).error, 'photo not found');
  assertEquals(calls, [`find:${MEAL}`]);
});

Deno.test('photo-url: 파기된 사진(purged_at)은 404', async () => {
  const { deps, calls } = fakeDeps({ ...mine, purged_at: '2026-10-20T00:00:00Z' });
  const res = await photoUrlResponse(post({ meal_id: MEAL }), deps);
  assertEquals(res.status, 404);
  assertEquals((await res.json()).error, 'photo not found');
  assertEquals(calls, [`find:${MEAL}`]);
});

Deno.test('photo-url: 끼니가 없거나, 사진 없이 기록했거나, 탈퇴로 주인이 없으면 404 — 남의 끼니와 같은 응답', async () => {
  for (const row of [null, { ...mine, storage_path: null }, { ...mine, owner_user_id: null }]) {
    const res = await photoUrlResponse(post({ meal_id: MEAL }), fakeDeps(row).deps);
    assertEquals(res.status, 404);
    assertEquals(await res.json(), { error: 'photo not found' });
  }
});

Deno.test('photo-url: 로그인 없으면 401, 끼니를 읽지 않는다', async () => {
  const { deps, calls } = fakeDeps(mine);
  for (const auth of [null, 'Bearer someone-else']) {
    const res = await photoUrlResponse(post({ meal_id: MEAL }, auth), deps);
    assertEquals(res.status, 401);
  }
  assertEquals(calls, []);
});

Deno.test('photo-url: 실제 requireUser — Authorization 이 없거나 틀린 토큰이면 401', async () => {
  Deno.env.set('SUPABASE_URL', 'https://example.supabase.co');
  Deno.env.set('SUPABASE_ANON_KEY', 'ANON_KEY');
  const realFetch = globalThis.fetch;
  globalThis.fetch = ((input: Request | URL | string, init?: RequestInit) => {
    const req = new Request(input, init);
    if (req.url.endsWith('/auth/v1/user')) return Promise.resolve(Response.json({ code: 'bad_jwt', msg: 'invalid JWT' }, { status: 403 }));
    return Promise.reject(new Error(`unexpected fetch ${req.url}`));
  }) as typeof fetch;
  try {
    const { deps, calls } = fakeDeps(mine, { requireUser });
    for (const auth of [null, 'Bearer BAD_JWT']) {
      const res = await photoUrlResponse(post({ meal_id: MEAL }, auth), deps);
      assertEquals(res.status, 401);
    }
    assertEquals(calls, []);
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test('photo-url: meal_id 가 UUID 가 아니면 422, POST 가 아니면 405, OPTIONS 는 CORS', async () => {
  for (const body of [{}, { meal_id: 'm-1' }, { meal_id: 3 }]) {
    assertEquals((await photoUrlResponse(post(body), fakeDeps(mine).deps)).status, 422);
  }
  assertEquals((await photoUrlResponse(post(null, 'Bearer ME', 'GET'), fakeDeps(mine).deps)).status, 405);
  const opt = await photoUrlResponse(new Request('https://fn.example/photo-url', { method: 'OPTIONS' }), fakeDeps(mine).deps);
  assertEquals(opt.status, 200);
  assertEquals(opt.headers.get('access-control-allow-origin'), '*');
});

Deno.test('photo-url: 서명에 실패하면 502', async () => {
  const { deps } = fakeDeps(mine, { signDownload: () => Promise.resolve(null) });
  assertEquals((await photoUrlResponse(post({ meal_id: MEAL }), deps)).status, 502);
});
