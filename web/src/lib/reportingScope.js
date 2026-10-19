import { rpc } from './api.js';

// Fetch fresh exclusions so every report uses the server's current policy.
export async function reportingExclusions() {
  return new Set(await rpc('get_reporting_excluded_users'));
}

export function withoutExcluded(rows, excluded, key = 'promoter_id') {
  return rows.filter((row) => !excluded.has(row[key]));
}

export function applyReportingScope(query, excluded) {
  return excluded.size ? query.not('promoter_id', 'in', `(${[...excluded].join(',')})`) : query;
}
