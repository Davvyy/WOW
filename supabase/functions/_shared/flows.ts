// 참가자 쓰기 흐름(05 API #8·#9·#22). I/O는 deps 로 주입해 단위 테스트한다. 규칙 판정은 모두 SQL 함수.
import { HttpError } from './http.ts';
import { imageSize, sha256Bytes } from './image.ts';

// ---------------------------------------------------------------- POST meals
export interface CreateMealDeps {
  download(path: string): Promise<Uint8Array | null>;
  photoPath(photoId: string): Promise<string | null>;
  verifyPhoto(m: { photo_id: string; sha256: string; bytes: number; width: number; height: number }): Promise<{ verified: boolean }>;
  createMeal(photoId: string, queued: boolean, snack: boolean): Promise<Record<string, unknown> & { meal_id: string; analyze?: boolean }>;
  triggerAnalyze(mealId: string): Promise<void>;
}

export async function createMealFlow(deps: CreateMealDeps, body: { photo_id?: unknown; queued?: unknown; slot?: unknown }) {
  if (typeof body.photo_id !== 'string') throw new HttpError(422, 'photo_id');
  const path = await deps.photoPath(body.photo_id);
  if (!path) throw new HttpError(404, 'photo not found');
  const bytes = await deps.download(path);
  if (!bytes) throw new HttpError(422, '사진 객체가 없어요. 다시 올려 주세요'); // 객체 없는 photo 행은 끼니 생성 거부
  const size = imageSize(bytes);
  if (!size) throw new HttpError(422, 'JPEG/PNG 만 받을 수 있어요');
  const v = await deps.verifyPhoto({ photo_id: body.photo_id, sha256: await sha256Bytes(bytes), bytes: bytes.length, width: size.width, height: size.height });
  if (!v.verified) throw new HttpError(422, '사진이 업로드 정보와 달라요(photo_mismatch)');
  // 촬영 화면에서 간식을 고른 경우만 사용자 선택을 따른다. 아침·점심·저녁은 서버 시각으로 태그(D55)
  const meal = await deps.createMeal(body.photo_id, body.queued === true, body.slot === 'snack');
  // 3초 안에 홈 복귀: 분석은 기다리지 않는다
  if (meal.analyze && !meal.replayed) await deps.triggerAnalyze(meal.meal_id);
  return meal;
}

// ---------------------------------------------------------------- DELETE account
export interface DeleteAccountDeps {
  deleteRows(confirm: string): Promise<{ storage_paths: string[]; participants: number; deleted: Record<string, number> }>;
  removeObjects(paths: string[]): Promise<void>;
  disableAuthUser(): Promise<void>;
}

export async function deleteAccountFlow(deps: DeleteAccountDeps, body: { confirm?: unknown }) {
  if (body.confirm !== '삭제') throw new HttpError(422, '확인을 위해 "삭제"를 입력해 주세요');
  const r = await deps.deleteRows(body.confirm);            // DB: 즉시 삭제·익명화(한 트랜잭션)
  for (let i = 0; i < r.storage_paths.length; i += 100) {   // Storage 원본 삭제
    await deps.removeObjects(r.storage_paths.slice(i, i + 100));
  }
  await deps.disableAuthUser();                             // 즉시 로그인 차단(소프트 삭제, 30일 내 하드 삭제)
  return { photos_removed: r.storage_paths.length, participants: r.participants, deleted: r.deleted };
}
