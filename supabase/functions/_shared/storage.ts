// Storage 객체 일괄 삭제: 사진 파기(purge-photos·purge-due)·끼니 삭제(meal-delete)가 SQL 이 돌려준 경로를 지운다.
import { HttpError } from './http.ts';

/** supabase-js `storage.from(bucket)` 중 remove 만. 테스트는 가짜로 바꾼다. */
export interface RemovableStorage {
  remove(paths: string[]): Promise<{ error: { message: string } | null }>;
}

/**
 * 100개씩 나눠 지운다.
 * 기본: 실패하면 502 로 멈춘다(purge-photos).
 * collectFailures: 모든 배치를 시도하고 실패한 경로를 돌려준다. 호출자가 unmark_photos_purged 로 purged_at 을 되돌려
 * 다음 자동 파기에서 다시 지우게 한다(purge-due·meal-delete).
 */
export function removeInBatches(storage: RemovableStorage, paths: string[], size?: number): Promise<void>;
export function removeInBatches(storage: RemovableStorage, paths: string[], size: number | undefined,
  opts: { collectFailures: true }): Promise<string[]>;
export async function removeInBatches(storage: RemovableStorage, paths: string[], size = 100,
  opts: { collectFailures?: boolean } = {}): Promise<string[] | void> {
  const failed: string[] = [];
  for (let i = 0; i < paths.length; i += size) {
    const batch = paths.slice(i, i + size);
    if (!opts.collectFailures) {
      const { error } = await storage.remove(batch);
      if (error) throw new HttpError(502, `storage remove: ${error.message}`);
      continue;
    }
    try {
      const { error } = await storage.remove(batch);
      if (error) failed.push(...batch);
    } catch {
      failed.push(...batch);
    }
  }
  if (opts.collectFailures) return failed;
}
