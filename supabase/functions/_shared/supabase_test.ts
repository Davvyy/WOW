import { assertEquals } from '@std/assert';
import { requireUser } from './supabase.ts';

Deno.test('requireUser: 요청의 사용자 토큰만 Authorization 으로 인증 서버에 보낸다(익명 키와 섞이지 않음)', async () => {
  Deno.env.set('SUPABASE_URL', 'https://example.supabase.co');
  Deno.env.set('SUPABASE_ANON_KEY', 'ANON_KEY');
  const seen: (string | null)[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = ((input: Request | URL | string, init?: RequestInit) => {
    const req = new Request(input, init);
    if (req.url.endsWith('/auth/v1/user')) {
      seen.push(req.headers.get('authorization'));
      const bearer = req.headers.get('authorization');
      return Promise.resolve(bearer === 'Bearer USER_JWT'
        ? Response.json({ id: 'u1', aud: 'authenticated', role: 'authenticated', app_metadata: {}, user_metadata: {}, created_at: '' })
        : Response.json({ code: 'bad_jwt', msg: 'invalid JWT' }, { status: 403 }));
    }
    return realFetch(input, init);
  }) as typeof fetch;
  try {
    const user = await requireUser(new Request('https://fn.example/sync-activity', { headers: { authorization: 'Bearer USER_JWT' } }));
    assertEquals(seen, ['Bearer USER_JWT']);
    assertEquals(user.id, 'u1');
  } finally {
    globalThis.fetch = realFetch;
  }
});
