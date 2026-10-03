// POST /functions/v1/purge-due — 사진 원본 자동 파기(docs/02 D56). pg_cron(pg_net)이 매일 03:30 KST 에 호출.
// 헤더 x-cron-secret = CRON_SECRET. 대상 판정·purged_at 기록은 SQL purge_due_photos 가 하고, 여기서는 Storage 객체를 지운다.
// 삭제에 실패한 경로는 purged_at 을 되돌려(unmark_photos_purged) 다음 실행이 다시 지우게 하고 502 {failed} 로 알린다.
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
    const paths = (data?.paths ?? []) as string[];
    const failed = await removeInBatches(db.storage.from('meal-photos'), paths, 100, { collectFailures: true });
    if (failed.length > 0) {
      console.error('purge-due storage remove failed', failed);
      const { error: unmarkError } = await db.rpc('unmark_photos_purged', { p_paths: failed });
      if (unmarkError) console.error('purge-due unmark failed', unmarkError.message);
      return json({ failed: failed.length }, 502);
    }
    return json({ challenges: data?.challenges ?? 0, count: data?.count ?? 0 });
  })
);
