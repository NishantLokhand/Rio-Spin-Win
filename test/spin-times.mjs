import assert from 'node:assert/strict';
import { attachSpinTimes, duration } from '../web/src/lib/spinTimes.js';
const times=[{key:'a',date:'2026-10-21',first_spin_at:'2026-10-21T04:30:00Z',last_spin_at:'2026-10-21T13:00:45Z',activity_span_seconds:30645},
 {key:'b',date:'2026-10-21',first_spin_at:'2026-10-20T18:40:00Z',last_spin_at:'2026-10-20T18:40:00Z',activity_span_seconds:0}];
const rows=attachSpinTimes([{key:'a',date:'2026-10-21',spins:5},{key:'b',date:'2026-10-21',spins:1},{key:'c',date:'2026-10-21',spins:0}],times);
assert.equal(rows[0].first_spin_time,'10:00:00');assert.equal(rows[0].last_spin_time,'18:30:45');assert.equal(rows[0].activity_span,'8h 30m');
assert.equal(rows[1].first_spin_time,'00:10:00');assert.equal(rows[1].last_spin_time,rows[1].first_spin_time);assert.equal(rows[1].activity_span,'0h 00m');
assert.equal(rows[2].first_spin_time,'N/A');assert.equal(rows[2].last_spin_time,'N/A');assert.equal(rows[2].activity_span,'0h 00m');
assert.equal(attachSpinTimes([{key:'a',date:'2026-10-20',spins:1}],times)[0].activity_span,'N/A');
assert.equal(attachSpinTimes([{key:'a',date:'2026-10-21'}],times,true)[0].first_spin_time,'N/A');
assert.equal(duration(60),'0h 01m');assert.equal(duration(90000),'25h 00m');
console.log('PASS: IST clock conversion, exact single-spin times, zero-spin defaults, day isolation, minute precision and summary handling.');
