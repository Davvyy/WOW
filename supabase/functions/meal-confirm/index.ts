// POST /functions/v1/meal-confirm {meal_id, items[]}  (05 API #12 F:/meals/{id}/confirm)
// 헤더: If-Match = meals.version(낙관적 잠금, 불일치 412), Idempotency-Key(UUID, 같은 키·같은 본문 재전송은 저장 응답).
// kcal 계산·하향 수정 플래그·48h 정정 창·잠정 재계산은 SQL confirm_meal 이 한다.
import { confirmMealFlow } from '../_shared/flows.ts';
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { withIdempotency } from '../_shared/idempotency.ts';
import { PgIdempotencyStore, requireUser, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await requireUser(req);
    const body = await req.json();
    const version = Number(req.headers.get('if-match'));
    if (typeof body.meal_id !== 'string' || !Array.isArray(body.items)) throw new HttpError(422, 'meal_id, items[]');
    if (!Number.isInteger(version) || version < 1) throw new HttpError(428, 'If-Match: version 헤더가 필요해요');
    const db = serviceClient();
    const out = await withIdempotency(new PgIdempotencyStore(db), user.id, req.headers.get('idempotency-key'), 'meal-confirm', { ...body, version }, async () => {
      // AI 가 낱개 포장 하나로 본 항목을 '몇 개입'으로 1개 단위로 바꾼 것은 단위 정정: AI 초안도 같은 단위로 맞춘 뒤 확정한다(D67).
      // 맞추지 못해도 확정은 그대로 한다(그때는 confirm_meal 이 예전처럼 판정).
      const data = await confirmMealFlow({
        async rebase(a) {
          const { error } = await db.rpc('rebase_ai_kcal_for_pieces', { p_user: user.id, p_meal: a.meal_id, p_items: a.items, p_version: a.version });
          if (error) throw error;
        },
        async confirm(a) {
          const { data, error } = await db.rpc('confirm_meal', { p_user: user.id, p_meal: a.meal_id, p_items: a.items, p_version: a.version });
          if (error) throw fromDbError(error);
          return data;
        },
        log: (e) => console.error('rebase_ai_kcal_for_pieces', e),
      }, { meal_id: body.meal_id, items: body.items, version });
      return { status: 200, body: data };
    });
    return json(out.body, out.status);
  })
);
