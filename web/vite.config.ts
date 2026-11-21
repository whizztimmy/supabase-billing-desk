import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

// In development, with no Supabase project configured, serve the database
// from PGlite at /rest/v1 so the console runs offline. See scripts/local-api.mjs.
function localDatabase(): Plugin {
  return {
    name: 'billing-desk-local-database',
    apply: 'serve',
    async configureServer(server) {
      if (process.env.VITE_SUPABASE_URL) return;
      // A computed path keeps this development-only file out of the type check.
      const file = '../scripts/local-api.mjs';
      const { createLocalApi } = await import(/* @vite-ignore */ file);
      server.middlewares.use(createLocalApi());
      server.config.logger.info('  Local database: PGlite, loaded from supabase/migrations and seed.sql');
    },
  };
}

export default defineConfig({
  plugins: [react(), localDatabase()],
  server: { port: 5174, strictPort: true },
});
