// POST /functions/v1/meal-manual {slot, items[], local_date?}  (05 API #10 F:/meals/manual)
// 사진 없는 직접 입력·검색·최근 음식 확정. 하루 3건 이상이면 manual_input_burst 플래그(값 유지).
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { withIdempotency } from '../_shared/idempotency.ts';
import { PgIdempotencyStore, requireUser, serviceClient } from '../_shared/supabase.ts';

const SLOTS = new Set(['breakfast', 'lunch', 'dinner', 'snack']);

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const b = await req.json();
    if (!SLOTS.has(b.slot) || !Array.isArray(b.items)) throw new HttpError(422, 'slot, items[]');
    const db = serviceClient();
    const out = await withIdempotency(new PgIdempotencyStore(db), user.id, req.headers.get('idempotency-key'), 'meal-manual', b, async () => {
      const { data, error } = await db.rpc('create_manual_meal', { p_user: user.id, p_slot: b.slot, p_items: b.items, p_local_date: b.local_date ?? null });
      if (error) throw fromDbError(error);
      return { status: 201, body: data };
    });
    return json(out.body, out.status);
  })
);
