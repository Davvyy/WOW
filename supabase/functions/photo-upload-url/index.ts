// POST /functions/v1/photo-upload-url {sha256, bytes, width, height, client_captured_at?}  (05 API #8)
// 기기에서 리사이즈(긴 변 ≤1,568 px)·EXIF 제거·SHA-256 계산 후 호출 → photo_id + 서명 PUT URL.
// 서버 수신 시각(server_received_at)이 신뢰 시각. 업로드 후 POST /meals 가 객체를 다시 읽어 재검증한다.
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { withIdempotency } from '../_shared/idempotency.ts';
import { PgIdempotencyStore, requireUser, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const b = await req.json();
    const db = serviceClient();
    const out = await withIdempotency(new PgIdempotencyStore(db), user.id, req.headers.get('idempotency-key'), 'photo-upload-url', b, async () => {
      const { data, error } = await db.rpc('create_photo', {
        p_user: user.id, p_sha256: b.sha256, p_bytes: b.bytes, p_width: b.width, p_height: b.height,
        p_client_captured_at: b.client_captured_at ?? null,
      });
      if (error) throw fromDbError(error);
      const { data: up, error: e2 } = await db.storage.from('meal-photos').createSignedUploadUrl(data.storage_path);
      if (e2 || !up) throw new HttpError(502, `signed url: ${e2?.message}`);
      return { status: 200, body: { photo_id: data.photo_id, storage_path: data.storage_path, signed_url: up.signedUrl, token: up.token,
        server_received_at: data.server_received_at } };
    });
    return json(out.body, out.status);
  })
);
