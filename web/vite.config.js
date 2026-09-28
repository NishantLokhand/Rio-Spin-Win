import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const target = env.VITE_SUPABASE_URL;
  return {
    plugins: [react()],
    server: {
      host: true,
      port: 5173,
      // With VITE_USE_PROXY=true the browser calls http://localhost:5173/sb/... and Vite forwards to Supabase
      // (useful if your internet provider blocks *.supabase.co)
      proxy: target && /^https?:\/\//.test(target)
        ? { '/sb': { target, changeOrigin: true, secure: true, rewrite: (p) => p.replace(/^\/sb/, '') } }
        : undefined,
    },
    build: { chunkSizeWarningLimit: 1200 },
  };
});
