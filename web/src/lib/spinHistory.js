import { shiftDate } from './reportDates.js';
import { summarizeActivity } from './userActivity.js';
export { shiftDate, historyRange } from './reportDates.js';

export function spinHistory(rows, { from = '', to, today }, people = [], accounts = []) {
  if (!to || to > today || (from && from > to)) throw new Error('Choose a valid date range ending today or earlier.');
  const org = new Map(people.map((p) => [p.auth_user_id, p]));
  const accountDates = new Map(accounts.map((a) => [a.key, a.account_date]));
  const groups = new Map();
  for (const r of rows) {
    if (!groups.has(r.key)) groups.set(r.key, []);
    groups.get(r.key).push(r);
  }
  const summary = [], daily = [];
  const completedEnd = to < today ? to : shiftDate(today, -1);
  for (const [id, userRows] of groups) {
    const spun = userRows.filter((r) => Number(r.spins) > 0).sort((a, b) => a.date.localeCompare(b.date));
    if (!spun.length || spun[0].date > to) continue;
    const first = spun[0].date;
    const last = spun.at(-1).date;
    const latest = [...userRows].sort((a, b) => b.date.localeCompare(a.date))[0];
    const person = org.get(id) || {};
    const base = { key: id, label: latest.label, user_type: latest.user_type,
      state: person.state_raw || latest.state || '',
      city: person.market_override ?? person.market_raw ?? latest.city ?? '', user_code: latest.user_code || '',
      area: person.area_override ?? person.area_raw ?? latest.area ?? '' };
    const byDate = new Map(userRows.map((r) => [r.date, r]));
    const accountStart = accountDates.get(id) || first;
    const start = from && from > accountStart ? from : accountStart;
    let active = 0, elapsed = 0, totalSpins = 0, streak = 0, longest = 0;
    for (let date = start; date <= to; date = shiftDate(date, 1)) {
      const r = byDate.get(date);
      const spins = Number(r?.spins || 0);
      totalSpins += spins;
      if (date <= completedEnd) {
        elapsed++;
        if (spins > 0) { active++; streak++; longest = Math.max(longest, streak); } else streak = 0;
      }
      daily.push({ ...base, ...r, id: `${id}:${date}`, date, spins, units: Number(r?.units || 0),
        giveaway_cost: Number(r?.giveaway_cost || 0), avg_cost: spins ? Number(r?.giveaway_cost || 0) / spins : 0,
        active_outlets: Number(r?.active_outlets || 0),
        outlets: r?.outlets || '', status: spins ? 'Spins recorded' : date === today ? 'Today in progress' : 'No spins recorded' });
    }
    const asOf = spun.filter((r) => r.date <= to).at(-1).date;
    const totals = summarizeActivity(userRows.filter((r) => r.date >= start && r.date <= to));
    summary.push({ ...base, ...totals, state: totals.state || base.state, city: totals.city || base.city, area: totals.area || base.area, date: to, first_spin: first, last_spin: last,
      last_spin_as_of: asOf, date_from: start, date_to: to, total_spins: totalSpins,
      active_days: active, no_spin_days: elapsed - active, completed_days: elapsed,
      consistency_pct: elapsed ? Math.round(active * 10000 / elapsed) / 100 : null,
      current_streak: streak, longest_streak: longest,
      days_since_last: Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${asOf}T00:00:00Z`)) / 86400000) });
  }
  summary.sort((a, b) => a.label.localeCompare(b.label));
  daily.sort((a, b) => b.date.localeCompare(a.date) || a.label.localeCompare(b.label));
  return { summary, daily };
}
