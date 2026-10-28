import { zeroActivityRows } from './userActivity.js';
import { attachMetrics } from './performanceMetrics.js';
import { attachSpinTimes } from './spinTimes.js';

// Add roster gaps only when no recorded activity exists for that user/date.
// Transaction filters cannot be assigned to a date without a transaction.
export const activityFilters = ['campaign_id', 'territory_id', 'tse_id', 'outlet_id', 'distributor', 'product_id'];

export function completeUserPerformance(source, recorded, filters, userType, today, prizeBreakdown = null) {
  const to = filters.date_to && filters.date_to < today ? filters.date_to : today;
  const users = new Map(source.users.map((u) => [u.id, u]));
  const rows = attachMetrics(recorded, source.metrics, filters.date_from, filters.date_to, today)
    .map((r) => ({ ...r, prizes_given: prizeBreakdown?.get(r.key) || '',
      account_status: users.get(r.key)?.is_active === false ? 'Disabled' : 'Active',
      activity: Number(r.spins) > 0 ? 'Spins recorded' : r.date === today ? 'Today in progress' : 'No spins recorded' }));
  if ((!filters.date_from || filters.date_from <= to) && !activityFilters.some((key) => filters[key])) {
    const recordedDates = new Set(source.rows.map((r) => `${r.key}:${r.date}`));
    const stateName = source.states.find((s) => s.id === filters.state_id)?.name;
    const gaps = zeroActivityRows(source, { from: filters.date_from, to, today, userType, userId: filters.promoter_id })
      .filter((r) => !recordedDates.has(`${r.key}:${r.date}`)
        && (!filters.state_id || r.state === stateName)
        && (!filters.city || r.city === filters.city)
        && (!filters.area || r.area === filters.area));
    rows.push(...gaps);
  }
  return attachSpinTimes(rows, source.spinTimes).sort((a, b) => b.date.localeCompare(a.date) || a.label.localeCompare(b.label));
}
