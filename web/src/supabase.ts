import { createClient } from '@supabase/supabase-js';

// Production reads the project URL and the public anon key from the build
// environment. In development, with neither set, the client talks to the
// PGlite stand-in the Vite dev server mounts at /rest/v1 (scripts/local-api.mjs).
const configuredUrl = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const configuredKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const usingLocalDatabase = import.meta.env.DEV && !configuredUrl;

if (!usingLocalDatabase && (!configuredUrl || !configuredKey)) {
  throw new Error('VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY must be set for a production build.');
}

export const supabase = createClient(
  usingLocalDatabase ? window.location.origin : configuredUrl!,
  usingLocalDatabase ? 'local-development' : configuredKey!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
