/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'node',
    include: ['src/**/*.test.{ts,tsx}'],
    // 실제 서버 주소가 든 .env 가 있어도 테스트는 모의 데이터로 돈다.
    env: { VITE_SUPABASE_URL: '', VITE_SUPABASE_ANON_KEY: '' },
    // 이중 패키지(ESM/CJS) 복제를 막아 react-router 컨텍스트가 하나만 쓰이게 한다.
    server: { deps: { inline: [/@refinedev/, /react-router/] } },
  },
});
