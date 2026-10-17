import assert from 'node:assert/strict';
import { zeroSpinUsers } from '../web/src/lib/zeroSpins.js';

const users = [
  { id: 'a', full_name: 'Same name', is_active: true },
  { id: 'b', full_name: 'Same name', is_active: false },
  { id: 'c', full_name: 'No activity', is_active: true },
];
const profiles = users.map((u) => ({ user_id: u.id, promoter_code: u.id }));
const dates = { date_from: '2026-10-17', date_to: '2026-10-17' };
// Historical name changes can produce multiple activity rows for the same user.
const rows = zeroSpinUsers(users, profiles, [
  { key: 'a', spins: 0 }, { key: 'a', spins: 2 }, { key: 'b', spins: 0 },
], dates);
assert.deepEqual(rows.map((r) => r.id), ['b', 'c']);
assert.equal(rows[0].status, 'Disabled');
assert.equal(rows[1].date_from, dates.date_from);
assert.equal(rows[1].date_to, dates.date_to);
assert.equal(zeroSpinUsers(users, [], []).length, 0);
assert.equal(zeroSpinUsers(users, profiles, []).length, 3);
assert.throws(() => zeroSpinUsers(users, profiles, [{ key: 'a', spins: 'bad' }]));
console.log('Zero-spin export checks passed.');
