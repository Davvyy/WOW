// POST /functions/v1/verdict {review_id, verdict, reason_template?, dry_run}  (05 API #28)
// 호출자 JWT 로 apply_verdict_rpc 를 부른다: 함수 안에서 운영자 여부를 검사하고 actor 를 본인으로 고정.
// 확정(dry_run=false)은 Idempotency-Key 필수. 통지 문장은 사유+판정+점수 영향 템플릿 조합만(SQL verdict_message).
import { handle, HttpError, json, fromDbError } from '../_shared/http.ts';
import { withIdempotency } from '../_shared/idempotency.ts';
import { PgIdempotencyStore, requireUser, serviceClient } from '../_shared/supabase.ts';

const VERDICTS = new Set(['approve', 'warn', 'void', 'exclude']);

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const body = await req.json();
    if (typeof body.review_id !== 'string' || !VERDICTS.has(body.verdict)) throw new HttpError(422, 'review_id, verdict');
    const call = async () => {
      const { data, error } = await user.client.rpc('apply_verdict_rpc', {
        p_review_id: body.review_id, p_verdict: body.verdict, p_dry_run: body.dry_run !== false, p_reason_template: body.reason_template ?? null,
      });
      if (error) throw fromDbError(error);
      return { status: 200, body: data };
    };
    if (body.dry_run !== false) return json((await call()).body);
    const out = await withIdempotency(new PgIdempotencyStore(serviceClient()), user.id, req.headers.get('idempotency-key'), 'verdict', body, call);
    return json(out.body, out.status, out.replayed ? { 'idempotent-replayed': 'true' } : {});
  })
);
