import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import master from './fixtures/userMasterMarkets.mjs';
import { profileMarket, reportMarketLookup, attachReportMarkets } from '../web/src/lib/reportMarkets.js';
import { requireFieldUserMarket } from '../supabase/functions/_shared/fieldUserMarket.mjs';
import { zeroActivityRows, zeroCohortRows } from '../web/src/lib/userActivity.js';
import { completeUserPerformance } from '../web/src/lib/userPerformance.js';
import { zeroSpinActivitySource } from '../web/src/lib/zeroSpinAudience.js';
import { userPerformanceColumns, dailyUserColumns, userReportColumns } from '../web/src/lib/userReportColumns.js';
import { BILL_COLUMNS, SPIN_COLUMNS, SKU_COLUMNS, transactionExcelRows } from '../web/src/staff/transactionReport.js';

const source = {
  users: [
    { id: 'active', login_id: '8318968669', full_name: 'Same name', is_active: true },
    { id: 'disabled', login_id: '8090244243', full_name: 'Same name', is_active: false },
    { id: 'new', login_id: 'new-user', full_name: 'New user', is_active: true },
  ],
  profiles: [], states: [], spinTimes: [],
  markets: [{ user_id: 'active', market: 'LUCKNOW' }, { user_id: 'disabled', market: 'VARANASI' }],
  people: [
    { auth_user_id: 'active', market_raw: 'UTTAR PRADESH', area_raw: 'Original area' },
    { auth_user_id: 'new', market_raw: 'Old market', market_override: 'New market' },
  ],
  metrics: ['active', 'disabled', 'new'].map(key => ({ key, account_date: '2026-11-01', spin_dates: [] })),
  rows: [], cutoffs: new Map([['disabled', '2026-11-04T09:00:00+05:30']]),
};
const range = { from: '2026-11-01', to: '2026-11-05', today: '2026-11-06' };

test('server-only mapping exactly preserves all 202 workbook login, code and Market records', () => {
  const sql = readFileSync(new URL('../supabase/migrations/20261119000100_report_user_markets.sql', import.meta.url), 'utf8');
  const tuples = [...sql.matchAll(/\('([^']*)', '([^']*)', '([^']*)'\)/g)].map(m => m.slice(1));
  assert.deepEqual(tuples, master);
  assert.equal(master.length, 202);
  assert.equal(new Set(master.map(r => r[0])).size, 202);
  assert.equal(new Set(master.map(r => r[1])).size, 202);
  for (const [login, code, market] of master) {
    assert.ok(market);
    assert.ok(login && code);
  }
  assert.equal(reportMarketLookup(source)('unknown', { full_name: 'AAKASH DEEP', city: 'Visited city' }), '');
});

test('master Market is separate from City/Area; new users use profile overrides', () => {
  const lookup = reportMarketLookup(source);
  const input = [{ key: 'active', city: 'UTTAR PRADESH', area: 'Original area', spins: 3, units: 4 }];
  const [row] = attachReportMarkets(input, lookup);
  assert.deepEqual(row, { ...input[0], market: 'LUCKNOW' });
  assert.equal(lookup('disabled'), 'VARANASI');
  assert.equal(lookup('new'), 'New market');
  assert.equal(profileMarket({ market_raw: 'Raw market' }), 'Raw market');
  assert.equal(profileMarket({ market_raw: 'Raw market', market_override: '' }), '');
  assert.equal(input[0].market, undefined);
});

test('zero-spin, never-spun, recorded and missing-date performance retain their populations and totals', () => {
  const gaps = zeroActivityRows(source, range);
  assert.equal(gaps.length, 13);
  assert.equal(gaps.find(r => r.key === 'active').market, 'LUCKNOW');
  assert.equal(gaps.find(r => r.key === 'active').city, 'UTTAR PRADESH');
  assert.ok(gaps.filter(r => r.key === 'disabled').every(r => r.date < '2026-11-04' && r.market === 'VARANASI'));
  assert.equal(zeroActivityRows(zeroSpinActivitySource(source), range).length, 10);
  assert.ok(zeroCohortRows(source, { ...range, never: true }).some(r => r.key === 'disabled' && r.market === 'VARANASI'));
  const recorded = [{ key: 'disabled', date: '2026-11-02', label: 'Historical user', spins: 2, units: 3, giveaway_cost: 10, city: 'Visited city' }];
  const rows = completeUserPerformance({ ...source, rows: recorded }, recorded,
    { date_from: range.from, date_to: range.to }, '', range.today);
  const historical = rows.find(r => r.key === 'disabled' && r.spins === 2);
  assert.equal(historical.market, 'VARANASI');
  assert.equal(historical.city, 'Visited city');
  assert.equal(historical.account_status, 'Disabled');
  assert.equal(rows.reduce((n, r) => n + r.units, 0), 3);
});

test('transaction bill, spin and SKU exports use the same Market with unchanged identities', () => {
  const lookup = reportMarketLookup(source);
  for (const columns of [BILL_COLUMNS, SPIN_COLUMNS, SKU_COLUMNS]) {
    const [row] = attachReportMarkets([{ promoter_id: 'active', transaction_id: 'bill', city: 'Outlet city', prize_cost: 7 }], lookup, 'promoter_id');
    const [excel] = transactionExcelRows([row], columns);
    assert.equal(excel.Market, 'LUCKNOW');
    assert.equal(excel.City, 'Outlet city');
    assert.equal(excel['Bill ID'], 'bill');
  }
  assert.equal(attachReportMarkets([{ user_id: 'disabled' }], lookup, 'user_id')[0].market, 'VARANASI');
});

test('shared performance, daily, history and zero-spin export columns include Market once', () => {
  for (const columns of [userPerformanceColumns, dailyUserColumns, userReportColumns(), BILL_COLUMNS, SPIN_COLUMNS, SKU_COLUMNS]) {
    assert.equal(columns.filter(c => c.key === 'market' && c.label === 'Market').length, 1);
  }
});

test('new field users require a nonblank text Market; non-field roles keep their existing behavior', () => {
  for (const invalid of [undefined, null, '', '   ', 123, {}, []]) {
    assert.throws(() => requireFieldUserMarket('promoter', invalid), /Market is required/);
  }
  assert.equal(requireFieldUserMarket('promoter', '  LUCKNOW  '), 'LUCKNOW');
  assert.equal(requireFieldUserMarket('admin', undefined), '');
  assert.equal(requireFieldUserMarket('supervisor', undefined), '');
});
