// POST /functions/v1/meal-skip {local_date, slot}  (05 API #13) — 1일 1회·주 3회, 초과분은 대체값
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { withIdempotency } from '../_shared/idempotency.ts';
import { PgIdempotencyStore, requireUser, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const body = await req.json();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(body.local_date ?? '') || !['breakfast', 'lunch', 'dinner'].includes(body.slot)) {
      throw new HttpError(422, 'local_date, slot(breakfast|lunch|dinner)');
    }
    const db = serviceClient();
    const { data: part } = await db.from('participants').select('id, challenges!inner(status)').eq('user_id', user.id)
      .in('challenges.status', ['checking', 'running']).limit(1).maybeSingle();
    if (!part) throw new HttpError(403, '진행 중인 챌린지가 없어요');
    const out = await withIdempotency(new PgIdempotencyStore(db), user.id, req.headers.get('idempotency-key'), 'meal-skip', body, async () => {
      const { data, error } = await db.rpc('skip_meal', { p_user: user.id, p_participant: part.id, p_date: body.local_date, p_slot: body.slot });
      if (error) throw fromDbError(error);
      return { status: 200, body: data };
    });
    return json(out.body, out.status);
  })
);
