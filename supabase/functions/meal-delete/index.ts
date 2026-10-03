// POST /functions/v1/meal-delete {meal_id}  (docs/02 D57) — 참가자가 확정 전 날짜의 자기 대표 끼니를 지운다.
// 헤더: Idempotency-Key(UUID, 같은 키·같은 본문 재전송은 저장 응답). 이미 지운 끼니를 새 키로 보내면 404.
// 복사본 삭제·점수 재계산·사진 purged_at 은 SQL delete_meal 이 하고(확인 중인 기록은 PT422), 여기서는 돌려받은 사진 원본을 Storage 에서 지운다.
// Storage 삭제가 실패하면 purged_at 을 되돌려(unmark_photos_purged) 자동 파기가 다시 지우게 하고, 200 본문에 photo_retry: true.
import { deleteMealFlow, mealIdOf } from '../_shared/flows.ts';
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { withIdempotency } from '../_shared/idempotency.ts';
import { removeInBatches } from '../_shared/storage.ts';
import { PgIdempotencyStore, requireUser, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const mealId = mealIdOf(await req.json().catch(() => null));
    const db = serviceClient();
    const out = await withIdempotency(new PgIdempotencyStore(db), user.id, req.headers.get('idempotency-key'), 'meal-delete', { meal_id: mealId }, async () => {
      const body = await deleteMealFlow({
        async deleteMeal(id) {
          const { data, error } = await db.rpc('delete_meal', { p_user: user.id, p_meal: id });
          if (error) throw fromDbError(error);
          return data;
        },
        removeObjects: (paths) => removeInBatches(db.storage.from('meal-photos'), paths, 100, { collectFailures: true }),
        async unmarkPurged(paths) {
          const { error } = await db.rpc('unmark_photos_purged', { p_paths: paths });
          if (error) throw fromDbError(error);
        },
      }, mealId);
      return { status: 200, body };
    });
    return json(out.body, out.status);
  })
);
