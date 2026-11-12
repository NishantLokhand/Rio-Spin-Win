import test from 'node:test';
import assert from 'node:assert/strict';
import { completeUserPerformance } from '../web/src/lib/userPerformance.js';
import { reportTotal } from '../web/src/lib/reportTotals.js';

// Synthetic regression fixtures, not a claim about these users' live activity.
const day = '2026-11-11';
const states = [{ id: 'mh', name: 'Maharashtra' }, { id: 'up', name: 'Uttar Pradesh' }];
const users = [
  { id: 'sunil', full_name: 'SUNIL KUMAR YADAV', state: 'MAHARASHTRA' },
  { id: 'harish', full_name: 'HARISHACHANDRA PATEL', state: ' Maharashtra ' },
  { id: 'up-upper', full_name: 'UP uppercase profile', state: 'UTTAR PRADESH' },
  { id: 'up-spaces', full_name: 'UP spaced profile', state: '  uttar   pradesh  ' },
  { id: 'recorded', full_name: 'Recorded activity', state: 'MAHARASHTRA' },
];
const recorded = [{ id: `recorded:${day}`, key: 'recorded', date: day, label: 'Recorded activity',
  state: 'Maharashtra', spins: 3, units: 3, giveaway_cost: 20, active_outlets: 1, outlets: 'Recorded shop' }];
const source = {
  users: users.map(u => ({ id: u.id, full_name: u.full_name, is_active: true })),
  states, profiles: [], rows: recorded, spinTimes: [],
  people: users.map(u => ({ auth_user_id: u.id, designation: 'PROMOTER', state_raw: u.state,
    market_raw: 'Original workbook market', area_raw: 'Original workbook area' })),
  metrics: users.map(u => ({ key: u.id, account_date: '2026-10-01', spin_dates: u.id === 'recorded' ? [day] : [] })),
};
const filters = { date_from: day, date_to: day };
const run = state_id => completeUserPerformance(source, state_id === 'up' ? [] : recorded,
  { ...filters, ...(state_id ? { state_id } : {}) }, '', '2026-11-12');
const ids = rows => rows.map(r => r.key).sort();

test('Maharashtra includes uppercase and padded zero-spin profiles', () => {
  assert.deepEqual(ids(run('mh')), ['harish', 'recorded', 'sunil']);
});

test('Uttar Pradesh includes uppercase and spaced zero-spin profiles', () => {
  assert.deepEqual(ids(run('up')), ['up-spaces', 'up-upper']);
});

test('each state is isolated and the two state reports reconcile to All states', () => {
  assert.deepEqual([...ids(run('mh')), ...ids(run('up'))].sort(), ids(run()));
  assert.equal(run().length, 5);
  assert.deepEqual(reportTotal([...run('mh'), ...run('up')]), reportTotal(run()));
});

test('matching preserves original display values, activity, totals and input data', () => {
  const before = JSON.stringify(source);
  for (const row of [...run('mh'), ...run('up')]) {
    const input = users.find(u => u.id === row.key);
    if (row.key === 'recorded') {
      assert.equal(row.spins, 3);
      assert.equal(row.outlets, 'Recorded shop');
    } else {
      assert.equal(row.state, input.state);
      assert.equal(row.city, 'Original workbook market');
      assert.equal(row.area, 'Original workbook area');
      assert.equal(row.spins, 0);
      assert.equal(row.outlets, '');
    }
  }
  assert.equal(JSON.stringify(source), before);
});

test('unknown state IDs cannot include profiles with blank states', () => {
  const blank = { ...source, people: source.people.map(p => ({ ...p, state_raw: '' })) };
  assert.deepEqual(completeUserPerformance(blank, [], { ...filters, state_id: 'unknown' }, '', '2026-11-12'), []);
});
