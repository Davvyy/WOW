// Storage 객체 일괄 삭제: 사진 파기(purge-photos·purge-due)가 SQL 이 돌려준 경로를 지운다.
import { HttpError } from './http.ts';

/** supabase-js `storage.from(bucket)` 중 remove 만. 테스트는 가짜로 바꾼다. */
export interface RemovableStorage {
  remove(paths: string[]): Promise<{ error: { message: string } | null }>;
}

/** 100개씩 나눠 지운다. 실패하면 502 로 멈춘다(purged_at 은 이미 기록돼 다시 돌려도 이 경로는 나오지 않음). */
export async function removeInBatches(storage: RemovableStorage, paths: string[], size = 100): Promise<void> {
  for (let i = 0; i < paths.length; i += size) {
    const { error } = await storage.remove(paths.slice(i, i + size));
    if (error) throw new HttpError(502, `storage remove: ${error.message}`);
  }
}
