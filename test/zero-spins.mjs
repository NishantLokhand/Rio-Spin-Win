import assert from 'node:assert/strict';
import { zeroSpinUsers, neverSpunUsers } from '../web/src/lib/zeroSpins.js';

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
const located = zeroSpinUsers(users, profiles, [], dates, [
  { auth_user_id: 'a', market_raw: 'ROM_AMRAVATI' },
  { auth_user_id: 'b', market_raw: 'Old city', market_override: 'MUMBAI MKT' },
  { auth_user_id: null, market_raw: 'Unlinked city' },
]);
assert.deepEqual(located.map((r) => r.city), ['ROM_AMRAVATI', 'MUMBAI MKT', '']);
assert.equal(located[1].status, 'Disabled');
const neverUsers = [
  ...users, { id: 'd', full_name: 'MER user', login_id: '9876543210' },
  { id: 'e', full_name: 'Unlinked', login_id: 'not-a-phone' },
];
const never = neverSpunUsers(neverUsers, [{ user_id: 'b', home_state_id: 'mh' }],
  [{ promoter_id: 'a' }, { promoter_id: 'a' }], [
    { auth_user_id: 'b', designation: 'PROMOTER', mobile: '9000000001', market_raw: 'ROM_AMRAVATI' },
    { auth_user_id: 'c', designation: 'TSE', state_raw: 'Uttar Pradesh' },
    { auth_user_id: 'd', designation: 'MER', market_raw: 'Old', market_override: 'MUMBAI MKT' },
  ], [{ id: 'mh', name: 'Maharashtra' }]);
assert.deepEqual(never.map((r) => r.id), ['b', 'c', 'd', 'e']);
assert.deepEqual(never.slice(0, 3).map((r) => r.type), ['Promoter', 'TSE', 'MER']);
assert.equal(never[0].state, 'Maharashtra');
assert.equal(never[1].state, 'Uttar Pradesh');
assert.equal(never[2].city, 'MUMBAI MKT');
assert.equal(never[0].mobile, '9000000001');
assert.equal(never[2].mobile, '9876543210');
assert.equal(never[3].mobile, '');
assert.ok(never.every((r) => r.spins === 0));
console.log('Zero-spin export checks passed.');
