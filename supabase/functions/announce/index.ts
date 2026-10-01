// POST /functions/v1/announce {challenge_id, title, body} — N-03 운영자 공지(API #29)
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { requireUser } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const b = await req.json();
    const { data, error } = await user.client.rpc('announce_challenge', { p_challenge_id: b.challenge_id, p_title: b.title, p_body: b.body });
    if (error) throw fromDbError(error);
    return json(data);
  })
);
