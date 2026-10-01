// GET /functions/v1/export?challenge_id=&type=ranking|scores|meals|activity — CSV 4종(API #30)
// 열 허용 목록은 SQL export_rows 에만 있다(health_alerts·operator_note·record_mode_reason 미포함).
import { toCsv } from '../_shared/csv.ts';
import { corsHeaders, fromDbError, handle, HttpError } from '../_shared/http.ts';
import { requireUser } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    const u = new URL(req.url);
    const type = u.searchParams.get('type'), challenge = u.searchParams.get('challenge_id');
    if (!type || !challenge) throw new HttpError(422, 'challenge_id, type');
    const user = await requireUser(req);
    const { data, error } = await user.client.rpc('export_rows', { p_challenge_id: challenge, p_type: type });
    if (error) throw fromDbError(error);
    return new Response(toCsv(data as Record<string, unknown>[]), {
      headers: { ...corsHeaders, 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="${type}.csv"` },
    });
  })
);
