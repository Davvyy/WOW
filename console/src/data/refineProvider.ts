import type { DataProvider } from '@refinedev/core';
import { dataProvider as supabaseDataProvider } from '@refinedev/supabase';
import type { ConsoleApi } from './api';
import { hasSupabaseEnv, supabase } from './supabaseClient';

/**
 * Refine용 데이터 provider.
 * Supabase 연결 시에는 @refinedev/supabase를 그대로 쓰고, 모의 데이터에서는 challenges 목록·단건만 흉내 낸다.
 * 화면의 도메인 호출(RPC·Edge Function·계산)은 ConsoleApi를 거치므로 Refine 리소스 CRUD는 보조 경로다.
 */
export function createRefineDataProvider(api: ConsoleApi): DataProvider {
  if (hasSupabaseEnv()) return supabaseDataProvider(supabase());
  const unsupported = (): never => { throw new Error('모의 데이터 provider에서는 지원하지 않는 호출이에요'); };
  return {
    getList: async () => {
      const rows = (await api.listChallenges()).map((s) => s.challenge);
      return { data: rows as never[], total: rows.length };
    },
    getOne: async ({ id }: { id: string | number }) => ({ data: (await api.getChallenge(String(id))) as never }),
    getApiUrl: () => 'mock://challory',
    create: unsupported, update: unsupported, deleteOne: unsupported,
  } as unknown as DataProvider;
}
