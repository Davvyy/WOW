// 참가자 쓰기 흐름(05 API #8·#9·#22). I/O는 deps 로 주입해 단위 테스트한다. 규칙 판정은 모두 SQL 함수.
import { HttpError } from './http.ts';
import { imageSize, sha256Bytes } from './image.ts';

// ---------------------------------------------------------------- POST meals
const MEAL_SLOTS = ['breakfast', 'lunch', 'dinner', 'snack'];

export interface CreateMealDeps {
  download(path: string): Promise<Uint8Array | null>;
  photoPath(photoId: string): Promise<string | null>;
  verifyPhoto(m: { photo_id: string; sha256: string; bytes: number; width: number; height: number }): Promise<{ verified: boolean }>;
  createMeal(photoId: string, queued: boolean, slot: string | null): Promise<Record<string, unknown> & { meal_id: string; analyze?: boolean }>;
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
  // 촬영 화면에서 고른 끼니로 저장한다(D58). 없거나 모르는 값이면 서버 시각으로 태그.
  const slot = typeof body.slot === 'string' && MEAL_SLOTS.includes(body.slot) ? body.slot : null;
  const meal = await deps.createMeal(body.photo_id, body.queued === true, slot);
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

// ---------------------------------------------------------------- POST meal-delete (docs/02 D57)
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 본문 검사: meal_id(UUID) 없으면 422. 멱등 키 검사보다 먼저 한다(meal-confirm 과 같은 순서). */
export function mealIdOf(body: unknown): string {
  const id = (body as { meal_id?: unknown } | null)?.meal_id;
  if (typeof id !== 'string' || !UUID.test(id)) throw new HttpError(422, 'meal_id');
  return id;
}

export interface DeletedMeal {
  meal_id: string;
  deleted: number;
  local_date: string;
  slot: string;
}

export interface DeleteMealDeps {
  deleteMeal(mealId: string): Promise<DeletedMeal & { purge_path?: string | null }>;
  /** 실패한 경로를 돌려준다(removeInBatches 수집 모드). */
  removeObjects(paths: string[]): Promise<string[]>;
  /** unmark_photos_purged: 다음 자동 파기(purge-due)가 다시 지우게 purged_at 을 되돌린다. */
  unmarkPurged(paths: string[]): Promise<void>;
}

export async function deleteMealFlow(deps: DeleteMealDeps, mealId: string): Promise<DeletedMeal & { photo_retry?: true }> {
  const r = await deps.deleteMeal(mealId); // DB: 그룹 삭제·재계산·사진 purged_at(한 트랜잭션)
  const body: DeletedMeal = { meal_id: r.meal_id, deleted: r.deleted, local_date: r.local_date, slot: r.slot };
  if (!r.purge_path) return body;
  const failed = await deps.removeObjects([r.purge_path]).catch(() => [r.purge_path as string]);
  if (failed.length === 0) return body;
  // DB 는 이미 지워졌다 → 200 을 돌려주고(재시도는 404 가 된다) 원본은 다음 자동 파기에서 지운다.
  console.error('meal-delete storage remove failed', failed);
  await deps.unmarkPurged(failed).catch((e) => console.error('meal-delete unmark failed', failed, e instanceof Error ? e.message : e));
  return { ...body, photo_retry: true };
}

// ---------------------------------------------------------------- POST meal-confirm
export interface ConfirmMealArgs {
  meal_id: string;
  items: unknown[];
  version: number;
}

export interface ConfirmMealDeps<R> {
  /** AI 가 낱개 포장 하나로 본 항목의 1개 단위 정정에 맞춰 AI 초안 kcal 을 다시 쓴다(rebase_ai_kcal_for_pieces, D67) */
  rebase(a: ConfirmMealArgs): Promise<void>;
  /** confirm_meal: kcal 계산·하향 수정 판정·정정 창·잠정 재계산 */
  confirm(a: ConfirmMealArgs): Promise<R>;
  log(e: unknown): void;
}

/** 확정: AI kcal 맞춤을 먼저, 그다음 confirm_meal. 맞춤이 안 되면 기록만 하고 확정은 그대로(그때는 예전처럼 판정). */
export async function confirmMealFlow<R>(deps: ConfirmMealDeps<R>, a: ConfirmMealArgs): Promise<R> {
  try {
    await deps.rebase(a);
  } catch (e) {
    deps.log(e);
  }
  return await deps.confirm(a);
}
