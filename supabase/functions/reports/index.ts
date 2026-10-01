// POST /functions/v1/reports {participant_id? | meal_id?, reason}  (05 API #19)
// 익명 신고: 신고자는 운영자 전용 review_reporters 에만 남고, 대상에게는 N-05 만 간다. 하루 3건(429).
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { withIdempotency } from '../_shared/idempotency.ts';
import { PgIdempotencyStore, requireUser, sendPendingNow, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const b = await req.json();
    if (typeof b.participant_id !== 'string' && typeof b.meal_id !== 'string') throw new HttpError(422, 'participant_id 또는 meal_id');
    const db = serviceClient();
    const out = await withIdempotency(new PgIdempotencyStore(db), user.id, req.headers.get('idempotency-key'), 'reports', b, async () => {
      const { data, error } = await db.rpc('submit_report', {
        p_user: user.id, p_target_participant: b.participant_id ?? null, p_meal: b.meal_id ?? null, p_reason: b.reason ?? '',
      });
      if (error) throw fromDbError(error);
      return { status: 201, body: { review_id: data.review_id } }; // 신고 결과·판정은 신고자에게 알리지 않는다
    });
    // 대상에게 N-05(검토 안내·소명 요청)를 바로. 22~08시 생성분은 예약 시각(08:00)까지 워커가 들고 있는다.
    if (!out.replayed && out.status === 201) await sendPendingNow(db, 'N-05', { review_id: (out.body as { review_id: string }).review_id });
    return json(out.body, out.status);
  })
);
