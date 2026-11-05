import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { buildTransactionReport, fetchTransactionReport, transactionExcelRows, BILL_COLUMNS, SPIN_COLUMNS, SKU_COLUMNS } from '../web/src/staff/transactionReport.js';
import { createTransactionWorkbook } from '../web/src/staff/transactionExport.js';
import * as XLSX from '../web/node_modules/xlsx/xlsx.mjs';
import { freezeExcelHeaders } from '../web/src/lib/freezeExcelHeaders.js';
import { unzipSync, strFromU8 } from '../web/node_modules/fflate/esm/index.mjs';

const spin = (n, patch = {}) => ({ id: `spin-${n}`, spin_id: `SPN-${n}`, spin_no: n, spin_date: '2026-11-02', spin_time: '13:00:00',
  spun_at: `2026-11-02T07:30:${String(n).padStart(2, '0')}Z`, prize_cost: n === 3 ? 200 : 10, prize_name: n === 3 ? 'Speaker' : 'INR10',
  redemption_status: 'handed_over', inventory_status: 'deducted', config_version: 6,
  distribution_version: n === 3 ? 8 : 7, distribution_mode: n === 3 ? 'speaker_third_daily' : 'snacks', ...patch });
const bill = (id = 'bill1', patch = {}) => ({ transaction_id: id, promoter_name: 'Field user', bill_date: '2026-11-02',
  bill_recorded_date: '2026-11-02', bill_time: '13:00:00', bill_created_at: '2026-11-02T07:30:00Z',
  bill_quantity: 6, spins_allowed: 6, stored_spins_used: 6, sale_status: 'completed', item_source: 'Bill items',
  items: [{ product_id: 'gold', sku_code: 'GOLD', product_name: 'Gold', quantity: 4 },
    { product_id: 'red', sku_code: 'RED', product_name: 'Red', quantity: 2 }], spins: Array.from({ length: 6 }, (_, i) => spin(i + 1)), ...patch });

test('one six-unit bill produces six prizes without repeating sales units', () => {
  const r = buildTransactionReport([bill()]);
  assert.deepEqual([r.bills.length, r.spins.length, r.skus.length, r.summary.units, r.summary.prize_cost], [1, 6, 2, 6, 250]);
  assert.equal(r.bills[0].data_check, 'OK');
  assert.equal(r.skus.reduce((n, r) => n + r.quantity, 0), 6);
  assert.ok(!SPIN_COLUMNS.some(c => /quantity|bill_quantity|sku_basket/.test(c.key)));
  assert.ok(!SKU_COLUMNS.some(c => /cost|spin_count|spins_recorded/.test(c.key)));
  assert.equal(r.spins.find(s => s.spin_no === 3).distribution_version, 8);
  assert.equal(r.spins.find(s => s.spin_no === 3).config_version, 6);
});
test('SKU filter retains whole matching bills/prizes but only matching SKU sales', () => {
  const r = buildTransactionReport([bill()], { product_id: 'red' });
  assert.deepEqual([r.bills.length, r.spins.length, r.skus.length, r.summary.units, r.summary.sku_units], [1, 6, 1, 6, 2]);
});
test('pending, undelivered and partial bills remain visible and reconcile', () => {
  const r = buildTransactionReport([bill('partial', { sale_status: 'spun', stored_spins_used: 3,
    spins: [spin(1), spin(2, { redemption_status: 'pending', inventory_status: 'reserved' }), spin(3, { redemption_status: 'not_redeemed', inventory_status: 'released' })] })]);
  const b = r.bills[0];
  assert.deepEqual([b.spins_recorded, b.unspun_units, b.handed_over, b.pending, b.not_redeemed, b.prize_cost, b.handed_over_cost], [3, 3, 1, 1, 1, 220, 10]);
  assert.equal(b.data_check, 'OK');
});
test('unspun/cancelled bills have zero fake spin rows; cancellation excludes units from totals', () => {
  const r = buildTransactionReport([bill('cancelled', { sale_status: 'cancelled', stored_spins_used: 0, spins: [] })]);
  assert.deepEqual([r.bills.length, r.spins.length, r.summary.units, r.summary.sku_units], [1, 0, 0, 0]);
  assert.equal(r.bills[0].bill_quantity, 6);
  assert.equal(r.skus[0].quantity, 4);
});
test('legacy distributions stay unknown and spin/handovers may cross bill dates', () => {
  const r = buildTransactionReport([bill('legacy', { stored_spins_used: 1, sale_status: 'spun', spins: [spin(1, {
    spin_date: '2026-11-03', spin_time: '00:01:00', distribution_version: null, distribution_mode: null,
    handover_date: '2026-11-04', handover_time: '09:00:00',
  })] })]);
  assert.equal(r.spins[0].distribution_version, 'Not recorded');
  assert.equal(r.spins[0].bill_date, '2026-11-02');
  assert.equal(r.spins[0].spin_date, '2026-11-03');
  assert.equal(r.spins[0].handover_date, '2026-11-04');
});
test('inconsistent bill totals are exposed; duplicate IDs and invalid data fail explicitly', () => {
  assert.match(buildTransactionReport([bill('bad', { bill_quantity: 7 })]).bills[0].data_check, /Bill\/SKU units differ/);
  assert.throws(() => buildTransactionReport([bill(), bill()]), /Duplicate or missing Bill/);
  assert.throws(() => buildTransactionReport([bill('a'), bill('b')]), /Duplicate or missing Spin/);
  assert.throws(() => buildTransactionReport([bill('bad', { bill_quantity: null })]), /invalid bill quantity/);
  assert.throws(() => buildTransactionReport([bill('bad', { spins: null })]), /Incomplete bill detail/);
});
test('empty filters return empty reports with genuine zero totals', () => {
  assert.deepEqual(buildTransactionReport([]).summary, { bills: 0, units: 0, sku_units: 0, spins: 0, handed_over: 0, pending: 0, prize_cost: 0, handed_over_cost: 0, checks: 0 });
});
test('currency totals reconcile in paise without floating-point drift', () => {
  const r = buildTransactionReport([bill('decimal', { bill_quantity: 2, spins_allowed: 2, stored_spins_used: 2,
    items: [{ product_id: 'one', quantity: 2 }], spins: [spin(1, { prize_cost: 0.1 }), spin(2, { prize_cost: 0.2 })] })]);
  assert.equal(r.summary.prize_cost, 0.3);
  assert.equal(r.summary.handed_over_cost, 0.3);
});
test('keyset pagination carries the server cutoff and never combines stale responses', async () => {
  const calls = [];
  const client = { rpc: async (name, args) => {
    calls.push(args);
    return { data: { as_of: '2026-11-05T00:00:00Z', bills: args.p_after_bill ? [bill('b', { spins: [], stored_spins_used: 0, sale_status: 'open' })] : [bill()], next_after: args.p_after_bill ? null : 'bill1' } };
  } };
  const r = await fetchTransactionReport(client, { promoter_id: 'person' });
  assert.equal(r.bills.length, 2);
  assert.equal(calls[1].p_as_of, '2026-11-05T00:00:00Z');
  assert.equal(calls[1].p_after_bill, 'bill1');
  assert.deepEqual(calls[0].p_filters, { promoter_id: 'person' });
  await assert.rejects(fetchTransactionReport({ rpc: async () => ({ data: { as_of: '2026-11-05', bills: [bill()], next_after: 'same' } }) }), /did not advance/);
  await assert.rejects(fetchTransactionReport({ rpc: async () => ({ error: { code: 'PGRST202' } }) }), /not installed/);
  const c = new AbortController(); c.abort();
  await assert.rejects(fetchTransactionReport(client, {}, c.signal), { name: 'AbortError' });
});
test('Excel has three correct datasets, numeric dates/times, filters and frozen headers', () => {
  const r = buildTransactionReport([bill()]);
  const sheets = [{ name: 'Bills', rows: r.bills, columns: BILL_COLUMNS }, { name: 'Spins', rows: r.spins, columns: SPIN_COLUMNS }, { name: 'SKU Sales', rows: r.skus, columns: SKU_COLUMNS }];
  const wb = createTransactionWorkbook(XLSX, sheets);
  const bytes = freezeExcelHeaders(XLSX.write(wb, { bookType: 'xlsx', type: 'array' }));
  const again = XLSX.read(bytes, { type: 'array', cellNF: true });
  assert.deepEqual(again.SheetNames, ['Bills', 'Spins', 'SKU Sales']);
  assert.equal(again.Sheets.Bills.A2.t, 'n');
  assert.equal(again.Sheets.Bills.B2.t, 'n');
  assert.equal(again.Sheets.Bills.A2.z, 'yyyy-mm-dd');
  assert.equal(again.Sheets.Bills.B2.z, 'hh:mm:ss');
  assert.equal(transactionExcelRows(r.bills, BILL_COLUMNS)[0]['Bill Date'], 46328);
  const files = unzipSync(bytes);
  for (let i = 1; i <= 3; i++) {
    const xml = strFromU8(files[`xl/worksheets/sheet${i}.xml`]);
    assert.match(xml, /state="frozen"/);
    assert.match(xml, /<autoFilter/);
  }
});
test('supplied 220-row export reconciles after the new report transformation', { skip: !process.env.TXN_SOURCE_JSON }, () => {
  const rows = JSON.parse(readFileSync(process.env.TXN_SOURCE_JSON, 'utf8'));
  const groups = Map.groupBy ? Map.groupBy(rows, r => r['Transaction ID']) : rows.reduce((m, r) => m.set(r['Transaction ID'], [...(m.get(r['Transaction ID']) || []), r]), new Map());
  const source = [...groups].map(([id, rs]) => {
    const first = rs[0];
    return bill(id, { bill_quantity: first.Quantity, spins_allowed: first.Quantity, stored_spins_used: rs.length,
      items: first.SKU.split(', ').map((s, i) => { const [, name, q] = s.match(/^(.*) × (\d+)$/); return { product_id: `${id}-${i}`, product_name: name, quantity: Number(q) }; }),
      spins: rs.map(r => ({ ...spin(r._excel_row), id: r['Spin ID'], spin_id: r['Spin ID'], prize_cost: r['Prize Cost'], config_version: r['Prize Config Version'], distribution_version: null, distribution_mode: null })),
    });
  });
  const r = buildTransactionReport(source);
  assert.deepEqual([r.bills.length, r.spins.length, r.summary.units, r.summary.sku_units, r.summary.prize_cost, r.summary.handed_over_cost], [40, 220, 220, 220, 2115, 2115]);
  assert.equal(r.summary.checks, 0);
});
