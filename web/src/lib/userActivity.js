import { shiftDate } from './reportDates.js';
import { performanceMetrics } from './performanceMetrics.js';
import { attachSpinTimes } from './spinTimes.js';

export function accountDate(user, metric) {
  return metric?.account_date || (user.created_at
    ? new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata' }).format(new Date(user.created_at)) : null);
}

export function summarizeActivity(rows) {
  const entries = new Map();
  for (const row of rows) for (const entry of row.outlet_entries || []) entries.set(entry.id, entry);
  const spins = rows.reduce((n, r) => n + Number(r.spins || 0), 0);
  const cost = rows.reduce((n, r) => n + Number(r.giveaway_cost || 0), 0);
  const labels = (field) => [...new Set(rows.map((r) => r[field]).filter(Boolean))].sort().join(', ');
  return {
    spins, units: rows.reduce((n, r) => n + Number(r.units || 0), 0), giveaway_cost: cost,
    avg_cost: spins ? Math.round(cost * 100 / spins) / 100 : 0,
    active_outlets: rows.every((r) => Array.isArray(r.outlet_entries)) ? entries.size
      : rows.length === 1 ? rows[0].active_outlets : rows.length ? null : 0,
    outlets: entries.size ? [...entries.values()].sort((a, b) => a.name.localeCompare(b.name))
      .map((e) => `${e.name} [${e.code || e.id}]`).join('; ') : [...new Set(rows.map((r) => r.outlets).filter(Boolean))].join('; '),
    state: labels('state'), city: labels('city'), area: labels('area'),
  };
}

function prepare(source) {
  const metrics = new Map(source.metrics.map((m) => [m.key, m]));
  const profiles = new Map(source.profiles.map((p) => [p.user_id, p]));
  const people = new Map(source.people.map((p) => [p.auth_user_id, p]));
  const states = new Map(source.states.map((s) => [s.id, s.name]));
  const rows = new Map(), spins = new Map();
  for (const m of source.metrics) spins.set(m.key, new Set(m.spin_dates || []));
  for (const r of source.rows) {
    if (!rows.has(r.key)) rows.set(r.key, new Map());
    rows.get(r.key).set(r.date, r);
    if (Number(r.spins) > 0) {
      if (!spins.has(r.key)) spins.set(r.key, new Set());
      spins.get(r.key).add(r.date);
    }
  }
  function identity(user) {
    const p = people.get(user.id) || {}, profile = profiles.get(user.id) || {};
    return { key: user.id, label: user.full_name,
      user_type: ({ PROMOTER: 'Promoter', TSE: 'TSE', MER: 'MER' })[p.designation] || 'Unknown',
      state: p.state_raw || states.get(profile.home_state_id) || '',
      city: p.market_override ?? p.market_raw ?? '', area: p.area_override ?? p.area_raw ?? '',
      user_code: profile.promoter_code || '', login: user.login_id,
      mobile: p.mobile || user.mobile || (/^\+?\d{10,15}$/.test(user.login_id || '') ? user.login_id : ''),
      account_status: user.is_active ? 'Active' : 'Disabled', account_date: accountDate(user, metrics.get(user.id)) };
  }
  return { metrics, rows, spins, identity, people };
}

function validateRange(from, to, today) {
  if (!to || to > today || (from && from > to)) throw new Error('Choose a valid date range ending today or earlier.');
}

export function zeroActivityRows(source, { from, to, today, userType = '', userId = '' }) {
  validateRange(from, to, today);
  const p = prepare(source), result = [];
  for (const user of source.users) {
    if ((userId && user.id !== userId) || (userType && p.people.get(user.id)?.designation !== userType)) continue;
    const identity = p.identity(user);
    if (!identity.account_date) throw new Error(`Account creation date is missing for ${user.full_name}.`);
    const start = from && from > identity.account_date ? from : identity.account_date;
    const metrics = performanceMetrics(p.metrics.get(user.id) || { key: user.id, account_date: identity.account_date, spin_dates: [...(p.spins.get(user.id) || [])] }, from, to, today);
    for (let date = start; date <= to; date = shiftDate(date, 1)) {
      if (p.spins.get(user.id)?.has(date)) continue;
      const activity = p.rows.get(user.id)?.get(date);
      result.push({ ...identity, ...metrics, ...activity, id: `${user.id}:${date}`, key: user.id, date,
        spins: 0, units: Number(activity?.units || 0), giveaway_cost: Number(activity?.giveaway_cost || 0),
        avg_cost: activity?.avg_cost ?? 0, active_outlets: Number(activity?.active_outlets || 0), outlets: activity?.outlets || '',
        date_from: start, date_to: to, activity: date === today ? 'Today in progress' : 'No spins recorded' });
    }
  }
  return attachSpinTimes(result, source.spinTimes).sort((a, b) => b.date.localeCompare(a.date) || a.label.localeCompare(b.label));
}

export function zeroCohortRows(source, { from = '', to, today, never = false }) {
  validateRange(from, to, today);
  const p = prepare(source), result = [];
  for (const user of source.users) {
    const identity = p.identity(user), dates = [...(p.spins.get(user.id) || [])];
    if (!identity.account_date) throw new Error(`Account creation date is missing for ${user.full_name}.`);
    if (identity.account_date > to || (never ? dates.length > 0 : dates.some((d) => (!from || d >= from) && d <= to))) continue;
    const start = from && from > identity.account_date ? from : identity.account_date;
    const rows = [...(p.rows.get(user.id)?.values() || [])].filter((r) => r.date >= start && r.date <= to);
    const aggregate = summarizeActivity(rows);
    const metrics = performanceMetrics(p.metrics.get(user.id) || { key: user.id, account_date: identity.account_date, spin_dates: dates }, start, to, today);
    result.push({ ...identity, ...metrics, ...aggregate, state: aggregate.state || identity.state,
      city: aggregate.city || identity.city, area: aggregate.area || identity.area,
      id: user.id, key: user.id, date: to, date_from: start, date_to: to, activity: never ? 'Never spun' : 'Zero spins throughout period' });
  }
  return attachSpinTimes(result, []).sort((a, b) => a.label.localeCompare(b.label));
}

export function isoWeek(date) {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
  const year = d.getUTCFullYear();
  const week = Math.ceil(((d - new Date(Date.UTC(year, 0, 1))) / 86400000 + 1) / 7);
  return `${year}-W${String(week).padStart(2, '0')}`;
}

export function zeroPeriod(mode, selection, today, includeToday = false) {
  const cutoff = includeToday ? today : shiftDate(today, -1);
  let from, to;
  if (mode === 'day') from = to = selection.day;
  else if (mode === 'week') {
    const match = /^(\d{4})-W(\d{2})$/.exec(selection.week || '');
    if (!match) throw new Error('Choose a week.');
    const jan4 = `${match[1]}-01-04`;
    const monday = shiftDate(jan4, -((new Date(`${jan4}T00:00:00Z`).getUTCDay() + 6) % 7));
    from = shiftDate(monday, (Number(match[2]) - 1) * 7); to = shiftDate(from, 6);
    if (isoWeek(from) !== selection.week) throw new Error('Choose a valid week.');
  } else if (mode === 'month') {
    if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(selection.month || '')) throw new Error('Choose a month.');
    from = `${selection.month}-01`;
    const d = new Date(`${from}T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() + 1);
    to = shiftDate(d.toISOString().slice(0, 10), -1);
  } else { from = selection.from; to = selection.to; }
  if (!from || !to || from > to) throw new Error('Choose a valid start and end date.');
  if (to > cutoff) to = cutoff;
  if (from > to) throw new Error('This period has no completed days. Choose an earlier period or include today.');
  return { from, to };
}
