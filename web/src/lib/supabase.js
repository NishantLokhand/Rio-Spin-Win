import { createClient } from '@supabase/supabase-js';
import { createDemoClient } from './demo/client.js';

const env = import.meta.env;
const useProxy = env.VITE_USE_PROXY === 'true';
export const SUPABASE_URL = useProxy ? `${window.location.origin}/sb` : env.VITE_SUPABASE_URL;
export const SUPABASE_ANON_KEY = env.VITE_SUPABASE_ANON_KEY;
export const LOGIN_DOMAIN = env.VITE_LOGIN_DOMAIN || 'login.riospinwin.app';

// true only when real Supabase settings are present in web/.env.local
export const isConfigured = Boolean(env.VITE_SUPABASE_URL && env.VITE_SUPABASE_ANON_KEY
  && !/YOUR-PROJECT-REF|YOUR-ANON-KEY/.test(env.VITE_SUPABASE_URL + env.VITE_SUPABASE_ANON_KEY));

// DEMO MODE: no Supabase settings (or VITE_DEMO_MODE=true) → in-browser sample backend for testing
export const DEMO = !isConfigured || env.VITE_DEMO_MODE === 'true';

export const supabase = DEMO ? createDemoClient() : createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: 'rio-auth', detectSessionInUrl: false },
});

/** Mobile number or username → synthetic Supabase Auth email */
export function loginEmail(loginId) {
  const id = String(loginId || '').trim().toLowerCase().replace(/\s+/g, '').replace(/^\+91/, '');
  return `${id}@${LOGIN_DOMAIN}`;
}
