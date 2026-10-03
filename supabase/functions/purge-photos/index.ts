// POST /functions/v1/purge-photos {challenge_id} — 운영자 사진 원본 파기(API #31): Archived·취소·종료+30일 후. 해시·메타는 남는다.
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { removeInBatches } from '../_shared/storage.ts';
import { requireUser, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const { challenge_id } = await req.json();
    // 운영자 검사·상태 검사·purged_at 기록은 SQL 이 한다
    const { data, error } = await user.client.rpc('purge_challenge_photos', { p_challenge_id: challenge_id });
    if (error) throw fromDbError(error);
    await removeInBatches(serviceClient().storage.from('meal-photos'), (data.paths ?? []) as string[]);
    return json({ count: data.count, purged_at: data.purged_at });
  })
);
