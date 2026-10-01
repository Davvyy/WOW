// POST /functions/v1/meal-confirm {meal_id, items[]}  (05 API #12 F:/meals/{id}/confirm)
// 헤더: If-Match = meals.version(낙관적 잠금, 불일치 412), Idempotency-Key(UUID, 같은 키·같은 본문 재전송은 저장 응답).
// kcal 계산·하향 수정 플래그·48h 정정 창·잠정 재계산은 SQL confirm_meal 이 한다.
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { withIdempotency } from '../_shared/idempotency.ts';
import { PgIdempotencyStore, requireUser, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const body = await req.json();
    const version = Number(req.headers.get('if-match'));
    if (typeof body.meal_id !== 'string' || !Array.isArray(body.items)) throw new HttpError(422, 'meal_id, items[]');
    if (!Number.isInteger(version) || version < 1) throw new HttpError(428, 'If-Match: version 헤더가 필요해요');
    const db = serviceClient();
    const out = await withIdempotency(new PgIdempotencyStore(db), user.id, req.headers.get('idempotency-key'), 'meal-confirm', { ...body, version }, async () => {
      const { data, error } = await db.rpc('confirm_meal', { p_user: user.id, p_meal: body.meal_id, p_items: body.items, p_version: version });
      if (error) throw fromDbError(error);
      return { status: 200, body: data };
    });
    return json(out.body, out.status);
  })
);
