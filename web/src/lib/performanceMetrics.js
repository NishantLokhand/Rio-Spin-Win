export const performanceColumns = [
  { key: 'active_days', label: 'Days With Spins' },
  { key: 'no_spin_days', label: 'Days Without Spins' },
  { key: 'activity_pct', label: 'Activity %' },
  { key: 'snack5_used_pct', label: '₹5 Snack Used % (Current)' },
  { key: 'snack10_used_pct', label: '₹10 Snack Used % (Current)' },
];

export function performanceMetrics(record, from, to, today) {
  if (!record) return { active_days: null, no_spin_days: null, activity_pct: null, snack5_used_pct: null, snack10_used_pct: null };
  const start = from && from > record.account_date ? from : record.account_date;
  const end = to && to < today ? to : new Date(Date.parse(`${today}T00:00:00Z`) - 86400000).toISOString().slice(0, 10);
  const days = start <= end ? Math.floor((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / 86400000) + 1 : 0;
  const active = new Set((record.spin_dates || []).filter((d) => d >= start && d <= end)).size;
  return { ...record, active_days: active, no_spin_days: days - active, completed_days: days,
    activity_pct: days ? Math.round(active * 10000 / days) / 100 : null };
}

export function attachMetrics(rows, metrics, from, to, today) {
  const byUser = new Map(metrics.map((m) => [m.key, m]));
  return rows.map((r) => ({ ...r, ...performanceMetrics(byUser.get(r.key || r.id), from, to, today),
    key: r.key, id: r.id }));
}
