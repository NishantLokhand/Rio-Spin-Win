import test from 'node:test';
import assert from 'node:assert/strict';
import { isZeroSpinDemoAccount, isZeroSpinExcludedAccount, zeroSpinAudience, zeroSpinReportSource } from '../web/src/lib/zeroSpinAudience.js';
import { zeroActivityRows, zeroCohortRows, zeroPeriod } from '../web/src/lib/userActivity.js';
import { completeUserPerformance } from '../web/src/lib/userPerformance.js';

const real = [
  { id: 'real', login_id: '9000000001', full_name: 'Field User', is_active: true },
  { id: 'disabled', login_id: '9000000002', full_name: 'Former Field User', is_active: false },
  { id: 'name', login_id: 'demodhar', full_name: 'Demodhar Patil', is_active: true },
];
const demo = ['demo01', 'demo02', 'demo03', 'demo04', 'demo005', 'demo007', 'demo008', 'demo009', 'DEMO_10', 'test01']
  .map(id => ({ id, login_id: id, full_name: id, is_active: true }));
demo.push({ id: 'renamed-login', login_id: '9000000003', full_name: 'Rio demo01', is_active: false });
const sneha = { id: 'sneha', login_id: '9876500002', full_name: 'Sneha Yadav', is_active: true };
const users = [...real, ...demo, sneha];
const people = users.map(u => ({ auth_user_id: u.id, designation: u.id === 'disabled' ? 'TSE' : 'PROMOTER' }));
const source = { users, people, profiles: [], states: [], rows: [], spinTimes: [],
  metrics: users.map(u => ({ key: u.id, account_date: '2026-11-01', spin_dates: [] })),
  cutoffs: new Map([['disabled', '2026-11-04T09:00:00+05:30']]),
};
const range = { from: '2026-11-01', to: '2026-11-05', today: '2026-11-06' };

test('recognizes demo/test logins and names without excluding similarly named real people', () => {
  assert.ok(demo.every(isZeroSpinDemoAccount));
  assert.ok(real.every(u => !isZeroSpinDemoAccount(u)));
  assert.equal(isZeroSpinDemoAccount({ login_id: ' DEMO01 ', full_name: 'Renamed user' }), true);
  assert.equal(isZeroSpinDemoAccount({ login_id: '9000000000', full_name: 'Test Promoter 1' }), true);
  assert.equal(isZeroSpinDemoAccount({ login_id: 'testament', full_name: 'Testa Singh' }), false);
  assert.equal(isZeroSpinDemoAccount({}), false);
});
test('Sneha Yadav is excluded only from the zero-spin audience; similar names remain', () => {
  assert.equal(isZeroSpinExcludedAccount(sneha), true);
  assert.equal(isZeroSpinExcludedAccount({ full_name: '  SNEHA   YADAV ', login_id: 'changed-login' }), true);
  assert.equal(isZeroSpinExcludedAccount({ full_name: 'Renamed user', login_id: '9876500002' }), true);
  for (const full_name of ['Sonu Yadav', 'Snehal Yadav', 'Sneha Sharma']) {
    assert.equal(isZeroSpinExcludedAccount({ full_name, login_id: '9000000010' }), false);
  }
  assert.ok(!zeroSpinAudience(users, people).some(u => u.id === sneha.id));
  assert.ok(!zeroActivityRows(zeroSpinReportSource(source), { ...range, userId: sneha.id }).length);
  assert.ok(zeroCohortRows(source, { ...range, never: true }).some(r => r.key === sneha.id));
});
test('daily zero-spin rows and user-day counts exclude all demos, including the old demo01–04 exception', () => {
  const rows = zeroActivityRows(zeroSpinReportSource(source), range);
  assert.deepEqual([...new Set(rows.map(r => r.key))].sort(), ['disabled', 'name', 'real']);
  assert.equal(rows.length, 13); // Five days each for active real users; three before the disabled user's cutoff.
  assert.ok(rows.every(r => !r.key.startsWith('demo') && !r.key.startsWith('test')));
  assert.ok(rows.filter(r => r.key === 'disabled').every(r => r.date < '2026-11-04'));
});
test('weekly, monthly, custom and include-today selections use the same demo-free population', () => {
  for (const period of [zeroPeriod('week', { week: '2026-W45' }, range.today), zeroPeriod('month', { month: '2026-11' }, range.today),
    zeroPeriod('custom', { from: range.from, to: range.to }, range.today), zeroPeriod('day', { day: range.today }, range.today, true)]) {
    const rows = zeroActivityRows(zeroSpinReportSource(source), { ...period, today: range.today });
    assert.ok(rows.length > 0);
    assert.ok(rows.every(r => real.some(u => u.id === r.key)));
  }
});
test('zero-spin summary download excludes demos; never-spun report behavior remains unchanged', () => {
  assert.deepEqual(zeroCohortRows(zeroSpinReportSource(source), range).map(r => r.key).sort(), ['disabled', 'name', 'real']);
  assert.equal(zeroCohortRows(source, { ...range, never: true }).length, users.length);
});
test('user/type dropdown and explicit demo selections cannot reintroduce demo rows', () => {
  assert.deepEqual(zeroSpinAudience(users, people, 'TSE').map(u => u.id), ['disabled']);
  assert.deepEqual(zeroSpinAudience(users, people, 'PROMOTER').map(u => u.id), ['real', 'name']);
  assert.equal(zeroSpinAudience(users, people).length, real.length);
  assert.equal(zeroActivityRows(zeroSpinReportSource(source), { ...range, userId: 'demo01' }).length, 0);
});
test('input records and stock/activity metadata remain unchanged', () => {
  const before = JSON.stringify(source);
  zeroSpinAudience(users, people); zeroActivityRows(zeroSpinReportSource(source), range); zeroCohortRows(zeroSpinReportSource(source), range);
  assert.equal(JSON.stringify(source), before);
  assert.equal(source.users.length, users.length);
});
test('shared user-performance logic and unfiltered activity sources are unchanged', () => {
  assert.ok(zeroActivityRows(source, range).some(r => r.key === 'demo01'));
  const rows = completeUserPerformance(source, [], { date_from: range.from, date_to: range.to }, '', range.today);
  assert.ok(rows.some(r => r.key === 'demo01'));
  assert.ok(rows.some(r => r.key === sneha.id));
  assert.equal(zeroSpinReportSource(source).metrics, source.metrics);
  assert.equal(zeroSpinReportSource(source).cutoffs, source.cutoffs);
});
