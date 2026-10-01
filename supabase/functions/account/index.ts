// DELETE /functions/v1/account {confirm: "삭제"}  (05 API #22, §8)
// 사진·식사·걸음·체중 기록은 즉시 삭제, 일별 점수만 익명으로 챌린지 종료까지 보존. 로그인은 즉시 차단.
import { deleteAccountFlow } from '../_shared/flows.ts';
import { fromDbError, handle, HttpError, json } from '../_shared/http.ts';
import { requireUser, serviceClient } from '../_shared/supabase.ts';

Deno.serve((req) =>
  handle(req, async (req) => {
    if (req.method !== 'DELETE' && req.method !== 'POST') throw new HttpError(405, 'DELETE only');
    const user = await requireUser(req);
    const body = await req.json().catch(() => ({}));
    const db = serviceClient();
    const out = await deleteAccountFlow({
      async deleteRows(confirm) {
        const { data, error } = await db.rpc('delete_account', { p_user: user.id, p_confirm: confirm });
        if (error) throw fromDbError(error);
        return data;
      },
      async removeObjects(paths) {
        const { error } = await db.storage.from('meal-photos').remove(paths);
        if (error) console.error('storage remove', error.message); // DB 는 이미 삭제됨 → 남은 객체는 종료+7일 파기에서 정리
      },
      async disableAuthUser() {
        const { error } = await db.auth.admin.deleteUser(user.id, true); // 소프트 삭제: 로그인 차단, 하드 삭제는 30일 내 배치
        if (error) throw new HttpError(502, `auth: ${error.message}`);
      },
    }, body);
    return json(out);
  })
);
