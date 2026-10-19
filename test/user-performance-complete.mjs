import assert from 'node:assert/strict';
import { completeUserPerformance, activityFilters } from '../web/src/lib/userPerformance.js';
import { reportTotal } from '../web/src/lib/reportTotals.js';
const source = {
  users: [{ id: 'a', full_name: 'Spinning', is_active: true }, { id: 'b', full_name: 'Disabled', is_active: false }],
  profiles: [], states: [{ id: 'mh', name: 'Maharashtra' }],
  people: [{ auth_user_id: 'a', designation: 'MER', state_raw: 'Maharashtra', market_raw: 'Profile City', area_raw: 'Profile Area' },
    { auth_user_id: 'b', designation: 'TSE', state_raw: 'Maharashtra', market_raw: 'Profile City', area_raw: 'Profile Area' }],
  metrics: [{ key: 'a', account_date: '2026-10-01', spin_dates: ['2026-10-01'] }, { key: 'b', account_date: '2026-10-02', spin_dates: [] }],
  rows: [{ id: 'a:2026-10-01', key: 'a', date: '2026-10-01', label: 'Spinning', spins: 2, units: 3, giveaway_cost: 10, outlets: 'Real shop', active_outlets: 1 },
    { id: 'a:2026-10-02', key: 'a', date: '2026-10-02', label: 'Spinning', spins: 0, units: 1, giveaway_cost: 0, outlets: 'Unspun purchase', active_outlets: 1 }],
};
const filters = { date_from: '2026-10-01', date_to: '2026-10-03' };
const run = (patch={}, recorded=source.rows, type='') => completeUserPerformance(source, recorded, { ...filters, ...patch }, type, '2026-10-03');
const rows = run();
assert.equal(rows.length, 5); // 3 user A dates, 2 user B dates since creation.
assert.equal(new Set(rows.map(r=>r.id)).size,5);
assert.equal(rows.find(r=>r.key==='b').account_status,'Disabled');
assert.equal(rows.find(r=>r.key==='b').activity,'Today in progress');
assert.equal(rows.find(r=>r.id==='a:2026-10-02').units,1);
assert.equal(rows.find(r=>r.id==='a:2026-10-02').outlets,'Unspun purchase');
assert.equal(rows.find(r=>r.id==='b:2026-10-02').outlets,'');
assert.equal(rows.find(r=>r.id==='b:2026-10-02').city,'Profile City');
assert.deepEqual(reportTotal(rows),reportTotal(source.rows));
for (const key of activityFilters) assert.equal(run({[key]:'filtered'}).length,2);
assert.equal(run({city:'Elsewhere'},[]).length,0);
assert.equal(run({city:'Profile City'},[]).length,3); // Existing activity excluded by filter never becomes fake zero rows.
assert.equal(run({state_id:'other'},[]).length,0);
assert.equal(run({state_id:'mh'},[]).length,3);
assert.equal(run({},[], 'TSE').length,2);
assert.equal(run({promoter_id:'b'},[]).length,2);
assert.deepEqual(run({date_from:'2026-10-04',date_to:'2026-10-05'},[]),[]);
assert.deepEqual(source.rows[0],{ id:'a:2026-10-01',key:'a',date:'2026-10-01',label:'Spinning',spins:2,units:3,giveaway_cost:10,outlets:'Real shop',active_outlets:1 });
console.log('PASS: Combined user/date rows, disabled users, account boundaries, real sales, totals, filters and unchanged input.');
