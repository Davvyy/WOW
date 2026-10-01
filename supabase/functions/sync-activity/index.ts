// POST /functions/v1/sync-activity  (05 API #6)
// 헤더 Idempotency-Key = client_batch_id. 본문은 05 §5 배치 포맷(집계값·세션·출처, kcal 없음).
import { handle, HttpError, json, fromDbError } from '../_shared/http.ts';
import { validateSyncBatch } from '../_shared/sync.ts';
import { requireUser, sendPendingNow, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const batch = validateSyncBatch(await req.json());
    const key = req.headers.get('idempotency-key');
    if (key && key !== batch.client_batch_id) throw new HttpError(422, 'Idempotency-Key 와 client_batch_id 가 달라요');
    const db = serviceClient();
    const { data: part, error } = await db.from('participants')
      .select('id, challenges!inner(status)').eq('user_id', user.id)
      .in('challenges.status', ['checking', 'running', 'closing']).order('joined_at', { ascending: false }).limit(1).maybeSingle();
    if (error) throw fromDbError(error);
    if (!part) throw new HttpError(403, '진행 중인 챌린지가 없어요');
    // 같은 배치 재전송은 저장된 결과(200), 같은 키·다른 본문은 409 — ingest_activity_batch 가 처리
    const { data, error: e2 } = await db.rpc('ingest_activity_batch', { p_participant: part.id, p_batch: batch });
    if (e2) throw fromDbError(e2);
    // 배치 검증이 플래그(걸음 급증·출처 불명 등)를 세웠으면 N-05 를 바로(낮 시간만, 밤에는 08:00 워커)
    await sendPendingNow(db, 'N-05', { user_id: user.id });
    return json(data);
  })
);
