/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'node',
    include: ['src/**/*.test.{ts,tsx}'],
    // 이중 패키지(ESM/CJS) 복제를 막아 react-router 컨텍스트가 하나만 쓰이게 한다.
    server: { deps: { inline: [/@refinedev/, /react-router/] } },
  },
});
