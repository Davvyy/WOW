import type { ConsoleApi } from './api';
import { createMockApi } from './mock/provider';
import { createSupabaseApi, hasSupabaseEnv } from './supabaseProvider';

let instance: ConsoleApi | null = null;

/** VITE_SUPABASE_URL이 있으면 Supabase, 없으면 모의 데이터. */
export function getApi(): ConsoleApi {
  if (!instance) {
    let scenario: string | undefined;
    try { scenario = new URLSearchParams(location.search).get('scenario') ?? localStorage.getItem('challory-mock-scenario') ?? undefined; } catch { /* 저장소 접근 불가 */ }
    instance = hasSupabaseEnv() ? createSupabaseApi() : createMockApi(scenario);
  }
  return instance;
}

export type { ConsoleApi } from './api';
