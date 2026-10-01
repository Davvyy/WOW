import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const hasSupabaseEnv = (): boolean => Boolean(url && url.trim());

let client: SupabaseClient | null = null;
export function supabase(): SupabaseClient {
  if (!client) {
    if (!url) throw new Error('VITE_SUPABASE_URL이 설정되지 않았어요');
    client = createClient(url, key ?? '');
  }
  return client;
}
