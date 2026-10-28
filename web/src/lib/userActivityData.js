import { rpc, selectAll } from './api.js';
import { reportingExclusions, withoutExcluded } from './reportingScope.js';

// Every source keeps its existing server-side staff scope. No name-based joins.
export async function loadUserActivityData() {
  const [users, profiles, people, states, rows, metrics, excluded, spinTimes, cutoffs] = await Promise.all([
    selectAll('app_users', 'id,full_name,login_id,mobile,is_active,created_at', (q) => q.eq('role', 'promoter').order('full_name')),
    selectAll('promoters', 'user_id,promoter_code,home_state_id'),
    selectAll('org_people', 'auth_user_id,designation,state_raw,market_raw,market_override,area_raw,area_override,mobile', (q) => q.not('auth_user_id', 'is', null)),
    selectAll('states', 'id,name'), rpc('report_user_daily', { p_filters: {}, p_user_type: null }), rpc('get_field_user_metrics'),
    reportingExclusions(),
    rpc('get_user_daily_spin_times'),
    rpc('get_deleted_field_user_cutoffs'),
  ]);
  return { users: withoutExcluded(users, excluded, 'id'), profiles, people, states,
    rows: withoutExcluded(rows, excluded, 'key'), metrics: withoutExcluded(metrics, excluded, 'key'), spinTimes,
    cutoffs: new Map((cutoffs || []).map((r) => [r.user_id, r.deleted_at])),
  };
}
