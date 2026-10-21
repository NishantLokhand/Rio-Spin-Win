import assert from 'node:assert/strict';
import { zeroActivityRows, zeroCohortRows, zeroPeriod, summarizeActivity } from '../web/src/lib/userActivity.js';
import { userPerformanceColumns, userReportColumns, dailyUserColumns } from '../web/src/lib/userReportColumns.js';
const source = {
  users: [{ id: 'a', full_name: 'Started then stopped', is_active: true }, { id: 'b', full_name: 'Never', is_active: false }],
  profiles: [], states: [],
  people: [{ auth_user_id: 'a', designation: 'MER', market_raw: 'ROM_BEED' }, { auth_user_id: 'b', designation: 'TSE' }],
  metrics: [{ key: 'a', account_date: '2026-10-01', spin_dates: ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04'] },
    { key: 'b', account_date: '2026-10-06', spin_dates: [] }],
  rows: [{ key: 'a', date: '2026-10-05', spins: 0, units: 2, giveaway_cost: 0, active_outlets: 1, outlets: 'Recorded visit', city: 'Actual city' }],
};
const range = { from: '2026-10-01', to: '2026-10-07', today: '2026-10-08' };
const daily = zeroActivityRows(source, range);
assert.deepEqual(daily.filter(r => r.key === 'a').map(r => r.date), ['2026-10-07', '2026-10-06', '2026-10-05']);
assert.deepEqual(daily.filter(r => r.key === 'b').map(r => r.date), ['2026-10-07', '2026-10-06']);
assert.equal(daily.find(r => r.date === '2026-10-05').units, 2);
assert.equal(daily.find(r => r.date === '2026-10-05').city, 'Actual city');
assert.equal(daily.find(r => r.key === 'b').account_status, 'Disabled');
assert.equal(zeroActivityRows(source, { ...range, userType: 'MER' }).length, 3);
assert.equal(zeroActivityRows(source, { ...range, userId: 'b' }).length, 2);
assert.deepEqual(zeroCohortRows(source, range).map(r => r.key), ['b']);
assert.deepEqual(zeroCohortRows(source, { ...range, never: true }).map(r => r.key), ['b']);
assert.equal(zeroActivityRows(source, { ...range, to: '2026-10-08' }).find(r => r.date === '2026-10-08').activity, 'Today in progress');
assert.deepEqual(zeroPeriod('month', { month: '2026-10' }, '2026-10-08'), { from: '2026-10-01', to: '2026-10-07' });
assert.deepEqual(zeroPeriod('month', { month: '2024-02' }, '2026-10-08'), { from: '2024-02-01', to: '2024-02-29' });
assert.deepEqual(zeroPeriod('week', { week: '2020-W53' }, '2026-10-08'), { from: '2020-12-28', to: '2021-01-03' });
assert.throws(() => zeroPeriod('week', { week: '2021-W53' }, '2026-10-08'));
assert.throws(() => zeroPeriod('day', { day: '2026-10-08' }, '2026-10-08'));
assert.deepEqual(zeroPeriod('day', { day: '2026-10-08' }, '2026-10-08', true), { from: '2026-10-08', to: '2026-10-08' });
const entry = { id: 'shop', name: 'Same shop', code: 'S1' };
const summary = summarizeActivity([{ outlet_entries: [entry], spins: 2, giveaway_cost: 10 }, { outlet_entries: [entry], spins: 3, giveaway_cost: 20 }]);
assert.equal(summary.active_outlets, 1); assert.equal(summary.spins, 5); assert.equal(summary.avg_cost, 6);
const columns = userReportColumns([{ key: 'date', label: 'Duplicate' }, { key: 'mobile', label: 'Mobile' }]);
assert.deepEqual(columns.slice(0, -1), userPerformanceColumns);
assert.equal(columns.at(-1).key, 'mobile');
assert.deepEqual(dailyUserColumns.map(c=>c.key),['date','label','user_type','state','city','area','outlets','active_outlets','spins','units','first_spin_time','last_spin_time','activity_span','giveaway_cost','avg_cost','snack5_used_pct','snack10_used_pct']);
assert.ok(userPerformanceColumns.some(c=>c.key==='activity_pct')); // Daily exclusions never remove the main report's fields.
assert.ok(userReportColumns().some(c=>c.key==='user_code'));
console.log('User activity cohorts, missing dates, calendar periods, outlet totals and shared columns passed.');
