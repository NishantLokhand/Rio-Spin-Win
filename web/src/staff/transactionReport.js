// Reporting only. One bill owns its complete SKU lines and recorded spins.
export const NOT_RECORDED = 'Not recorded';
const column = (key, label, extra = {}) => ({ key, label, ...extra });
const identityColumns = [
  column('promoter_name', 'User'), column('promoter_code', 'User Code'),
  column('state', 'State'), column('city', 'City'), column('area', 'Area'),
  column('outlet_name', 'Outlet'), column('outlet_code', 'Outlet Code'), column('outlet_license_no', 'Licence No.'),
];
const extraIdentityColumns = [
  column('campaign_code', 'Campaign'), column('territory', 'Territory'),
  column('tse_code', 'TSE Code'), column('tse_name', 'TSE Name'), column('outlet_address', 'Outlet Address'),
  column('distributor', 'Distributor'), column('promoter_type', 'Employment Type'),
];
export const BILL_COLUMNS = [
  column('bill_date', 'Bill Date'), column('bill_time', 'Bill Recorded Time (IST)'), ...identityColumns,
  column('transaction_id', 'Bill ID'), column('sku_basket', 'Bill SKU Basket'),
  column('bill_quantity', 'Bill Units Entered'), column('sales_units', 'Recorded Units (Excl. Cancelled)'),
  column('spins_allowed', 'Spins Allowed'), column('spins_recorded', 'Recorded Spins'), column('unspun_units', 'Unspun Units'),
  column('handed_over', 'Prizes Handed Over'), column('pending', 'Pending Handovers'), column('not_redeemed', 'Prizes Not Redeemed'),
  column('prize_cost', 'Recorded Prize Value'), column('handed_over_cost', 'Handed-over Prize Cost'),
  column('sale_status', 'Bill Status'), column('data_check', 'Data Check'), ...extraIdentityColumns,
  column('bill_recorded_date', 'Bill Recorded Date (IST)'), column('item_source', 'SKU Source'),
  column('cancelled_reason', 'Cancellation Reason'), column('device_ref', 'Device Ref'),
];
export const SPIN_COLUMNS = [
  column('spin_date', 'Spin Date (IST)'), column('spin_time', 'Spin Time (IST)'), ...identityColumns,
  column('spin_id', 'Spin ID'), column('transaction_id', 'Bill ID'), column('spin_no', 'Spin Number in Bill'),
  column('spin_count', 'Spin Count'), column('prize_name', 'Prize'), column('prize_cost', 'Prize Cost'),
  column('redemption_status', 'Handover Status'), column('inventory_status', 'Inventory Status'),
  column('handover_date', 'Handover Date (IST)'), column('handover_time', 'Handover Time (IST)'),
  column('config_version', 'Base Config Version'), column('distribution_version', 'Applied Distribution Version'),
  column('distribution_mode', 'Applied Distribution Mode'), column('bill_date', 'Bill Date'),
  column('sale_status', 'Bill Status'), column('substituted', 'Substituted'), ...extraIdentityColumns,
  column('device_ref', 'Device Ref'),
];
export const SKU_COLUMNS = [
  column('bill_date', 'Bill Date'), column('bill_time', 'Bill Recorded Time (IST)'), ...identityColumns,
  column('transaction_id', 'Bill ID'), column('sku_code', 'SKU Code'), column('product_name', 'SKU'),
  column('quantity', 'SKU Units Entered'), column('sales_units', 'Recorded SKU Units (Excl. Cancelled)'),
  column('sale_status', 'Bill Status'), column('item_source', 'SKU Source'), column('data_check', 'Bill Data Check'),
  ...extraIdentityColumns, column('bill_recorded_date', 'Bill Recorded Date (IST)'),
];
export const REPORT_VIEWS = [
  { key: 'bills', label: 'Bills / Sales', columns: BILL_COLUMNS },
  { key: 'spins', label: 'Spin / Prize Details', columns: SPIN_COLUMNS },
  { key: 'skus', label: 'SKU Sales', columns: SKU_COLUMNS },
];

const number = (value, label) => {
  if (value == null || value === '' || !Number.isFinite(Number(value))) throw new Error(`Missing or invalid ${label} in transaction report.`);
  return Number(value);
};
const byNewest = (field, id) => (a, b) => String(b[field] || '').localeCompare(String(a[field] || ''))
  || String(a[id]).localeCompare(String(b[id]));

export function buildTransactionReport(source, filters = {}) {
  const bills = []; const spins = []; const skus = [];
  const billIds = new Set(); const spinIds = new Set(); const spinCodes = new Set();
  for (const sourceBill of source) {
    const { items, spins: billSpins, ...base } = sourceBill;
    if (!base.transaction_id || billIds.has(base.transaction_id)) throw new Error('Duplicate or missing Bill ID in transaction report. Refresh the report.');
    billIds.add(base.transaction_id);
    if (!Array.isArray(items) || !items.length || !Array.isArray(billSpins)) throw new Error('Incomplete bill detail in transaction report.');
    const quantity = number(base.bill_quantity, 'bill quantity');
    const allowed = number(base.spins_allowed, 'spins allowed');
    const issues = []; const productIds = new Set();
    const itemUnits = items.reduce((sum, item) => {
      const key = item.product_id || item.sku_code;
      if (productIds.has(key)) issues.push('Repeated SKU line');
      productIds.add(key);
      return sum + number(item.quantity, 'SKU quantity');
    }, 0);
    if (itemUnits !== quantity) issues.push('Bill/SKU units differ');
    if (billSpins.length > allowed) issues.push('Recorded spins exceed allowance');
    if (number(base.stored_spins_used, 'stored spin count') !== billSpins.length) issues.push('Stored/recorded spins differ');
    if (base.sale_status === 'completed' && billSpins.length !== allowed) issues.push('Completed bill has unspun units');
    const statusCounts = { handed_over: 0, pending: 0, not_redeemed: 0 };
    let costPaise = 0; let handedPaise = 0;
    for (const spin of billSpins) {
      if (!spin.spin_id || !spin.id || spinIds.has(spin.id) || spinCodes.has(spin.spin_id)) throw new Error('Duplicate or missing Spin ID in transaction report. Refresh the report.');
      spinIds.add(spin.id); spinCodes.add(spin.spin_id);
      const spinCost = number(spin.prize_cost, 'prize cost');
      if (!Object.prototype.hasOwnProperty.call(statusCounts, spin.redemption_status)) issues.push('Unknown handover status');
      else statusCounts[spin.redemption_status]++;
      costPaise += Math.round(spinCost * 100);
      if (spin.redemption_status === 'handed_over') handedPaise += Math.round(spinCost * 100);
      spins.push({ ...base, ...spin, key: spin.id, spin_count: 1, prize_cost: spinCost,
        distribution_version: spin.distribution_version ?? NOT_RECORDED,
        distribution_mode: spin.distribution_mode || NOT_RECORDED,
      });
    }
    const dataCheck = [...new Set(issues)].join('; ') || 'OK';
    bills.push({ ...base, key: base.transaction_id, bill_quantity: quantity,
      sales_units: base.sale_status === 'cancelled' ? 0 : quantity,
      sku_basket: items.map(i => `${i.product_name || i.sku_code || NOT_RECORDED} × ${i.quantity}`).join(', '),
      spins_recorded: billSpins.length, unspun_units: Math.max(0, allowed - billSpins.length),
      ...statusCounts, prize_cost: costPaise / 100, handed_over_cost: handedPaise / 100, data_check: dataCheck,
    });
    for (const [i, item] of items.entries()) {
      if (filters.product_id && item.product_id !== filters.product_id) continue;
      const units = number(item.quantity, 'SKU quantity');
      skus.push({ ...base, ...item, key: `${base.transaction_id}:${item.product_id || i}`, quantity: units,
        sales_units: base.sale_status === 'cancelled' ? 0 : units, data_check: dataCheck,
      });
    }
  }
  bills.sort(byNewest('bill_created_at', 'transaction_id'));
  spins.sort(byNewest('spun_at', 'id'));
  skus.sort(byNewest('bill_created_at', 'key'));
  const sum = (rows, key) => rows.reduce((n, row) => n + row[key], 0);
  const sumMoney = key => bills.reduce((n, row) => n + Math.round(row[key] * 100), 0) / 100;
  return { bills, spins, skus, summary: {
    bills: bills.length, units: sum(bills, 'sales_units'), sku_units: sum(skus, 'sales_units'),
    spins: spins.length, handed_over: sum(bills, 'handed_over'), pending: sum(bills, 'pending'),
    prize_cost: sumMoney('prize_cost'), handed_over_cost: sumMoney('handed_over_cost'),
    checks: bills.filter(b => b.data_check !== 'OK').length,
  } };
}

export async function fetchTransactionReport(client, filters = {}, signal) {
  const bills = []; const cursors = new Set();
  let after = null; let asOf = null; let readAt = null;
  do {
    if (signal?.aborted) throw new DOMException('Report loading cancelled', 'AbortError');
    let query = client.rpc('transaction_report_page', { p_filters: filters, p_after_bill: after, p_as_of: asOf, p_limit: 250 });
    if (signal && query.abortSignal) query = query.abortSignal(signal);
    const { data, error } = await query;
    if (error) {
      if (error.code === 'PGRST202' || /function.*transaction_report_page.*(not|schema)|permission denied for function transaction_report_page/i.test(error.message || '')) {
        throw new Error('Transactions reporting update is not installed. Apply 20261105000100_transaction_report_datasets.sql in Supabase, then refresh this report.');
      }
      throw new Error(error.message || 'Could not load the transaction report.');
    }
    if (!data || !Array.isArray(data.bills) || !data.as_of) throw new Error('Incomplete transaction report response.');
    if (asOf && Date.parse(data.as_of) !== Date.parse(asOf)) throw new Error('Transaction report cutoff changed during loading. Refresh the report.');
    asOf = data.as_of; readAt = data.read_at;
    bills.push(...data.bills);
    after = data.next_after;
    if (after && (cursors.has(after) || !data.bills.length)) throw new Error('Transaction report pagination did not advance. Refresh the report.');
    if (after) cursors.add(after);
  } while (after);
  return { ...buildTransactionReport(bills, filters), as_of: asOf, read_at: readAt };
}

// These columns are shared with CSV. Only this report's Excel export converts
// dates/times to native sortable Excel serial values; other exports are untouched.
export function transactionExcelRows(rows, columns) {
  const dateKeys = new Set(['bill_date', 'bill_recorded_date', 'spin_date', 'handover_date']);
  const timeKeys = new Set(['bill_time', 'spin_time', 'handover_time']);
  return rows.map(row => Object.fromEntries(columns.map(({ key, label }) => {
    let value = row[key] ?? null;
    if (value && dateKeys.has(key)) value = (Date.parse(`${value}T00:00:00Z`) - Date.UTC(1899, 11, 30)) / 86400000;
    if (value && timeKeys.has(key)) value = value.split(':').reduce((n, part, index) => n + Number(part) * [3600, 60, 1][index], 0) / 86400;
    return [label, value];
  })));
}
