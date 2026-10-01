// POST /functions/v1/notify — 알림 발송 워커. pg_cron(pg_net) 또는 외부 스케줄러가 1~5분마다 호출.
// 헤더 x-cron-secret = CRON_SECRET. claim_due_notifications 가 권한 없음(no_push)·하루 4건 상한(daily_cap)을 거른다.
import { handle, HttpError, json, fromDbError } from '../_shared/http.ts';
import { selectPushSender } from '../_shared/push.ts';
import { env, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    const secret = env('CRON_SECRET');
    if (!secret || req.headers.get('x-cron-secret') !== secret) throw new HttpError(403, 'cron only');
    const db = serviceClient();
    const { data, error } = await db.rpc('claim_due_notifications', { p_limit: 200 });
    if (error) throw fromDbError(error);
    const push = selectPushSender(env);
    let sent = 0;
    for (const n of (data ?? []) as { id: string; title: string | null; body: string; type: string; payload: Record<string, unknown>; push_tokens: string[] }[]) {
      for (const token of n.push_tokens) {
        if (await push.send({ token, title: n.title, body: n.body, data: { type: n.type, id: n.id } })) sent++;
      }
    }
    return json({ claimed: data?.length ?? 0, sent });
  })
);
