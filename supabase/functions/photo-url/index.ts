// POST /functions/v1/photo-url {meal_id} → {meal_id, signed_url, expires_in: 300}
// 내 끼니 사진의 짧은 서명 다운로드 URL(meal-photos 는 비공개 버킷). 이 폰에 보관본이 없을 때(다시 설치·7일 지남·다른 폰) 앱이 부른다.
// 주인 확인: 끼니 → 참가 행 user_id = 호출자. 남의 끼니·사진 없음·파기(purged_at)는 모두 404. 규칙은 _shared/photo_url.ts.
import type { SupabaseClient } from '@supabase/supabase-js';
import { fromDbError, HttpError } from '../_shared/http.ts';
import { type MealPhotoRow, photoUrlResponse } from '../_shared/photo_url.ts';
import { requireUser, serviceClient } from '../_shared/supabase.ts';

async function findMealPhoto(db: SupabaseClient, mealId: string): Promise<MealPhotoRow | null> {
  const { data: meal, error } = await db.from('meals').select('participant_id, photo_id').eq('id', mealId).maybeSingle();
  if (error) throw fromDbError(error);
  if (!meal) return null;
  const { data: p, error: e2 } = await db.from('participants').select('user_id').eq('id', meal.participant_id).maybeSingle();
  if (e2) throw fromDbError(e2);
  const owner = (p?.user_id as string | null | undefined) ?? null;
  if (!meal.photo_id) return { owner_user_id: owner, storage_path: null, purged_at: null };
  const { data: ph, error: e3 } = await db.from('photos').select('storage_path, purged_at').eq('id', meal.photo_id).maybeSingle();
  if (e3) throw fromDbError(e3);
  return { owner_user_id: owner, storage_path: ph?.storage_path ?? null, purged_at: ph?.purged_at ?? null };
}

Deno.serve((req) => {
  let db: SupabaseClient | undefined;
  const svc = () => (db ??= serviceClient());
  return photoUrlResponse(req, {
    requireUser,
    findMealPhoto: (mealId) => findMealPhoto(svc(), mealId),
    async signDownload(path, expiresIn) {
      const { data, error } = await svc().storage.from('meal-photos').createSignedUrl(path, expiresIn);
      if (error) {
        if (/not.?found/i.test(error.message)) throw new HttpError(404, 'photo not found'); // 행은 있는데 객체가 없음
        console.error('photo-url sign', error.message);
        return null;
      }
      return data?.signedUrl ?? null;
    },
  });
});
