import assert from 'node:assert/strict';
import { historyRange, shiftDate, spinHistory } from '../web/src/lib/spinHistory.js';
assert.equal(shiftDate('2026-03-01', -1), '2026-02-28');
assert.deepEqual(historyRange('weekly', '2026-10-19'), { from: '2026-10-19', to: '2026-10-19' });
assert.deepEqual(historyRange('weekly', '2026-10-18'), { from: '2026-10-12', to: '2026-10-18' });
assert.deepEqual(historyRange('monthly', '2026-10-19'), { from: '2026-10-01', to: '2026-10-19' });
const rows = [
  { key: 'a', label: 'A', date: '2026-10-16', spins: 2, units: 2, outlets: 'Outlet 1', user_type: 'TSE' },
  { key: 'a', label: 'A', date: '2026-10-18', spins: 3, units: 3, outlets: 'Outlet 2', user_type: 'TSE' },
  { key: 'b', label: 'B', date: '2026-10-19', spins: 1, units: 1, user_type: 'MER' },
  { key: 'c', label: 'C', date: '2026-10-17', spins: 0, units: 1 },
];
const r = spinHistory(rows, { to: '2026-10-19', today: '2026-10-19' });
assert.equal(r.summary.length, 2); // Never-spun users remain in their separate report.
assert.equal(r.daily.filter((x) => x.key === 'a').length, 4);
const a = r.summary.find((x) => x.key === 'a');
assert.equal(a.total_spins, 5); assert.equal(a.completed_days, 3);
assert.equal(a.active_days, 2); assert.equal(a.no_spin_days, 1);
assert.equal(a.consistency_pct, 66.67); assert.equal(a.current_streak, 1);
assert.equal(a.first_spin, '2026-10-16'); assert.equal(a.last_spin, '2026-10-18');
assert.equal(a.days_since_last, 1);
const gap = r.daily.find((x) => x.key === 'a' && x.date === '2026-10-17');
assert.equal(gap.spins, 0); assert.equal(gap.outlets, ''); assert.equal(gap.status, 'No spins recorded');
assert.equal(r.daily.find((x) => x.key === 'a' && x.date === '2026-10-19').status, 'Today in progress');
assert.equal(r.summary.find((x) => x.key === 'b').consistency_pct, null);
assert.equal(new Set(r.daily.map((x) => x.id)).size, r.daily.length);
const past = spinHistory(rows, { from: '2026-10-17', to: '2026-10-17', today: '2026-10-19' });
assert.equal(past.summary.length, 1);
assert.equal(past.summary[0].first_spin, '2026-10-16');
assert.equal(past.summary[0].last_spin, '2026-10-18');
assert.equal(past.summary[0].last_spin_as_of, '2026-10-16');
assert.equal(past.summary[0].no_spin_days, 1);
assert.throws(() => spinHistory(rows, { from: '2026-10-20', to: '2026-10-19', today: '2026-10-19' }));
console.log('PASS: daily gaps, week/month ranges, historical endpoints, first/last spins, today exclusion, streaks and consistency.');
