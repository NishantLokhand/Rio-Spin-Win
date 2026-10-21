import assert from 'node:assert/strict';
import { seedDb, U } from '../web/src/lib/demo/seed.js';

const db = seedDb();
const shadeId = '50000000-0000-0000-0000-000000000004';
const pilots = [U.shade1, U.shade2, U.shade3, U.shade4, U.shade5];
const stock = (userId, prizeId) => db.promoter_inventory.find((row) => row.promoter_id === userId && row.prize_id === prizeId)?.on_hand || 0;

assert.equal(pilots.length, 5);
assert.equal(stock(U.shade1, shadeId), 20, 'Rio Pilot 01 must receive 20 Rio Shades');
for (const userId of pilots.slice(1)) assert.equal(stock(userId, shadeId), 0, 'Snack-only pilots must not receive Rio Shades');
for (const userId of pilots) {
  assert.equal(stock(userId, '50000000-0000-0000-0000-000000000001'), 152);
  assert.equal(stock(userId, '50000000-0000-0000-0000-000000000002'), 34);
}
assert.deepEqual(db._auth.filter((row) => pilots.includes(row.id)).map((row) => [row.email, row.password]), [
  ['demo-rio-shade-01', 'RioPilot01!'], ['demo-rio-shade-02', 'RioPilot02!'], ['demo-rio-shade-03', 'RioPilot03!'],
  ['demo-rio-shade-04', 'RioPilot04!'], ['demo-rio-shade-05', 'RioPilot05!'],
]);
console.log('Rio Shade eligibility fixture passed');
