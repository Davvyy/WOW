// POST photo-url {meal_id}: 내 끼니 사진의 짧은 서명 다운로드 URL. 버킷(meal-photos)은 비공개라 앱은 이 URL 로만 받는다.
// 다시 설치·7일 지남·다른 폰처럼 이 폰에 보관본이 없을 때 P7·홈 썸네일이 쓴다.
// 남의 끼니·사진 없는 끼니·파기된 사진(photos.purged_at)은 모두 404: 있는지도 알리지 않는다.
// I/O 는 deps 로 주입해 단위 테스트한다(photo_url_test.ts).
import { mealIdOf } from './flows.ts';
import { handle, HttpError, json } from './http.ts';

/** 서명 URL 유효 시간(초). 앱은 받자마자 내려받아 메모리에 둔다. */
export const PHOTO_URL_TTL_S = 300;

/** 끼니의 주인과 사진(서비스 키로 읽음). 끼니에 사진이 없으면 storage_path 는 null. */
export interface MealPhotoRow {
  owner_user_id: string | null;
  storage_path: string | null;
  purged_at: string | null;
}

export interface PhotoUrlDeps {
  /** 호출자 JWT 확인(없거나 틀리면 401 HttpError) */
  requireUser(req: Request): Promise<{ id: string }>;
  /** 끼니가 없으면 null */
  findMealPhoto(mealId: string): Promise<MealPhotoRow | null>;
  /** Storage createSignedUrl. 실패하면 null. */
  signDownload(path: string, expiresIn: number): Promise<string | null>;
}

export function photoUrlResponse(req: Request, deps: PhotoUrlDeps): Promise<Response> {
  return handle(req, async (req) => {
    if (req.method !== 'POST') throw new HttpError(405, 'POST only');
    const user = await deps.requireUser(req);
    const mealId = mealIdOf(await req.json().catch(() => null));
    const row = await deps.findMealPhoto(mealId);
    if (!row || row.owner_user_id !== user.id || !row.storage_path || row.purged_at) throw new HttpError(404, 'photo not found');
    const url = await deps.signDownload(row.storage_path, PHOTO_URL_TTL_S);
    if (!url) throw new HttpError(502, 'signed url');
    return json({ meal_id: mealId, signed_url: url, expires_in: PHOTO_URL_TTL_S });
  });
}
