// POST /functions/v1/meal-delete {meal_id}  (docs/02 D57) — 참가자가 확정 전 날짜의 자기 대표 끼니를 지운다.
// 헤더: Idempotency-Key(UUID, 같은 키·같은 본문 재전송은 저장 응답). 이미 지운 끼니를 새 키로 보내면 404.
// 복사본 삭제·점수 재계산·열린 검토 정리·사진 purged_at 은 SQL delete_meal 이 하고, 여기서는 돌려받은 사진 원본을 Storage 에서 지운다.
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
        removeObjects: (paths) => removeInBatches(db.storage.from('meal-photos'), paths),
      }, mealId);
      return { status: 200, body };
    });
    return json(out.body, out.status);
  })
);
