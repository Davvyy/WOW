// POST /functions/v1/meals {photo_id, queued?, slot?}  (05 API #9) — slot 은 촬영 화면에서 고른 끼니(D58)
// 서명 PUT 이 끝난 사진으로 끼니를 만든다: 객체 재검증(sha256·bytes·해상도) → 서버 KST 슬롯 태그·지연 업로드 규칙·중복 해시
// (SQL create_meal) → 국외 AI 동의자만 analyze-meal 을 백그라운드로 호출하고 즉시 반환(3초 내 홈 복귀).
import { createMealFlow } from '../_shared/flows.ts';
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { withIdempotency } from '../_shared/idempotency.ts';
import { env, PgIdempotencyStore, requireUser, serviceClient } from '../_shared/supabase.ts';

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const body = await req.json();
    const db = serviceClient();
    const out = await withIdempotency(new PgIdempotencyStore(db), user.id, req.headers.get('idempotency-key'), 'meals', body, async () => {
      const meal = await createMealFlow({
        async photoPath(id) {
          const { data } = await db.from('photos').select('storage_path').eq('id', id).maybeSingle();
          return data?.storage_path ?? null;
        },
        async download(path) {
          const { data, error } = await db.storage.from('meal-photos').download(path);
          return error || !data ? null : new Uint8Array(await data.arrayBuffer());
        },
        async verifyPhoto(m) {
          const { data, error } = await db.rpc('verify_photo', {
            p_user: user.id, p_photo: m.photo_id, p_sha256_server: m.sha256, p_bytes: m.bytes, p_width: m.width, p_height: m.height,
          });
          if (error) throw fromDbError(error);
          return data;
        },
        async createMeal(photoId, queued, slot) {
          const { data, error } = await db.rpc('create_meal', { p_user: user.id, p_photo: photoId, p_queued: queued, p_slot: slot });
          if (error) throw fromDbError(error);
          return data;
        },
        triggerAnalyze(mealId) {
          const call = fetch(`${env('SUPABASE_URL')}/functions/v1/analyze-meal`, {
            method: 'POST',
            headers: { 'content-type': 'application/json', 'x-internal-secret': env('INTERNAL_SECRET') ?? '',
              authorization: `Bearer ${env('SUPABASE_SERVICE_ROLE_KEY')}` },
            body: JSON.stringify({ meal_id: mealId }),
          }).then(() => {}, (e) => console.error('analyze-meal trigger', e));
          if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(call);
          return Promise.resolve();
        },
      }, body);
      return { status: 201, body: meal };
    });
    return json(out.body, out.status);
  })
);
