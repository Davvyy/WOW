// 공통 HTTP 유틸: JSON 응답, PostgREST 'PTnnn' 오류 → HTTP 상태, CORS
export const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, x-client-info, apikey, content-type, idempotency-key, if-match',
  'access-control-allow-methods': 'POST, GET, OPTIONS',
};

export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8', ...corsHeaders, ...extra } });
}

export class HttpError extends Error {
  constructor(public status: number, message: string, public detail?: unknown) {
    super(message);
  }
}

/** Postgres/PostgREST 오류 → HttpError. SQLSTATE 'PT412' → 412 등. */
export function fromDbError(e: { code?: string; message?: string; details?: string } | null | undefined): HttpError {
  const code = e?.code ?? '';
  const m = /^PT(\d{3})$/.exec(code);
  if (m) return new HttpError(Number(m[1]), e?.message ?? 'error', e?.details);
  if (code === '42501') return new HttpError(403, 'forbidden');
  if (code === '23505') return new HttpError(409, 'already exists');
  return new HttpError(500, e?.message ?? 'internal error');
}

export async function handle(req: Request, fn: (req: Request) => Promise<Response>): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    return await fn(req);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.message, detail: e.detail }, e.status);
    console.error(e);
    return json({ error: 'internal error' }, 500);
  }
}
