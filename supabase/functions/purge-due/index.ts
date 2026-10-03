// POST /functions/v1/purge-due — 사진 원본 자동 파기(docs/02 D56). pg_cron(pg_net)이 매일 03:30 KST 에 호출.
// 헤더 x-cron-secret = CRON_SECRET. 대상 판정·purged_at 기록은 SQL purge_due_photos 가 하고, 여기서는 Storage 객체를 지운다.
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { removeInBatches } from '../_shared/storage.ts';
import { env, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    const secret = env('CRON_SECRET');
    if (!secret || req.headers.get('x-cron-secret') !== secret) throw new HttpError(403, 'cron only');
    const db = serviceClient();
    const { data, error } = await db.rpc('purge_due_photos');
    if (error) throw fromDbError(error);
    await removeInBatches(db.storage.from('meal-photos'), (data.paths ?? []) as string[]);
    return json({ challenges: data.challenges, count: data.count });
  })
);
