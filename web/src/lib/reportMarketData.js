import { rpc, selectAll } from './api.js';
import { DEMO } from './supabase.js';
import { reportMarketLookup } from './reportMarkets.js';

// Read through the existing staff-scoped APIs, including disabled accounts.
export async function loadReportMarketLookup() {
  if (!DEMO) return reportMarketLookup({ markets: await rpc('get_report_user_markets') });
  const people = await selectAll('org_people', 'auth_user_id,market_raw,market_override', q => q.not('auth_user_id', 'is', null));
  return reportMarketLookup({ people });
}
