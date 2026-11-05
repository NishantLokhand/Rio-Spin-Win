import React, { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { exportCSV } from '../lib/exporter.js';
import { exportTransactionWorkbook } from './transactionExport.js';
import { fetchTransactionReport, REPORT_VIEWS } from './transactionReport.js';
import FilterBar from './FilterBar.jsx';
import { Panel, Loading, DataTable, Badge, Tabs, Kpi, fmt } from './ui.jsx';
import './Transactions.css';

export const TXN_COLUMNS = [
  { key: 'transaction_id', label: 'Transaction ID' }, { key: 'spin_id', label: 'Spin ID' }, { key: 'campaign_code', label: 'Campaign' },
  { key: 'date', label: 'Date' }, { key: 'time', label: 'Time' }, { key: 'state', label: 'State' }, { key: 'territory', label: 'Territory' },
  { key: 'tse_code', label: 'TSE Code' }, { key: 'tse_name', label: 'TSE Name' }, { key: 'outlet_code', label: 'Outlet Code' },
  { key: 'outlet_name', label: 'Outlet Name' }, { key: 'outlet_address', label: 'Outlet Address' },
  { key: 'outlet_license_no', label: 'Licence No.' }, { key: 'area', label: 'Area' }, { key: 'city', label: 'City' }, { key: 'distributor', label: 'Distributor' },
  { key: 'promoter_code', label: 'Promoter ID' }, { key: 'promoter_name', label: 'Promoter Name' }, { key: 'promoter_type', label: 'Promoter Type' },
  { key: 'sku_code', label: 'SKU Code' }, { key: 'sku', label: 'SKU' }, { key: 'quantity', label: 'Quantity' },
  { key: 'prize_name', label: 'Prize' }, { key: 'prize_cost', label: 'Prize Cost' }, { key: 'substituted', label: 'Substituted' },
  { key: 'redemption_status', label: 'Redemption Status' }, { key: 'inventory_status', label: 'Inventory Status' },
  { key: 'sale_status', label: 'Sale Status' }, { key: 'device_ref', label: 'Device Ref' }, { key: 'config_version', label: 'Prize Config Version' },
];

export function applyTxnFilters(q, f) {
  if (f.date_from) q = q.gte('date', f.date_from);
  if (f.date_to) q = q.lte('date', f.date_to);
  for (const k of ['campaign_id', 'state_id', 'territory_id', 'tse_id', 'outlet_id', 'promoter_id', 'area', 'city', 'distributor']) {
    if (f[k]) q = q.eq(k, f[k]);
  }
  if (f.product_id) q = q.contains('product_ids', [f.product_id]);
  return q;
}

export default function Transactions({ data, filters, setFilters }) {
  const [view, setView] = useState('bills');
  const [report, setReport] = useState({ loading: true, data: null, error: null });
  const [refresh, setRefresh] = useState(0);
  const [busy, setBusy] = useState(false);
  const [exportError, setExportError] = useState('');
  const filterKey = JSON.stringify(filters);
  useEffect(() => {
    const controller = new AbortController();
    setReport({ loading: true, data: null, error: null }); setExportError('');
    fetchTransactionReport(supabase, JSON.parse(filterKey), controller.signal)
      .then(result => { if (!controller.signal.aborted) setReport({ loading: false, data: result, error: null }); })
      .catch(error => { if (!controller.signal.aborted) setReport({ loading: false, data: null, error }); });
    return () => controller.abort();
  }, [filterKey, refresh]);

  async function downloadExcel() {
    setBusy(true);
    setExportError('');
    try {
      await exportTransactionWorkbook(REPORT_VIEWS.map(v => ({ name: v.key === 'bills' ? 'Bills' : v.key === 'spins' ? 'Spins' : 'SKU Sales',
        columns: v.columns, rows: report.data[v.key] })), `transactions_${filters.date_from || 'all'}_${filters.date_to || ''}`);
    } catch (error) {
      setExportError(error.message || 'Could not download the workbook.');
    } finally { setBusy(false); }
  }
  const selected = REPORT_VIEWS.find(v => v.key === view);
  const result = report.data;
  const moneyKeys = new Set(['prize_cost', 'handed_over_cost']);
  const countKeys = new Set(['bill_quantity', 'sales_units', 'spins_allowed', 'spins_recorded', 'unspun_units',
    'handed_over', 'pending', 'not_redeemed', 'spin_no', 'spin_count', 'quantity']);
  const tone = { handed_over: 'green', pending: 'amber', not_redeemed: 'red' };
  const screenKeys = {
    bills: ['bill_date', 'bill_recorded_date', 'bill_time', 'promoter_name', 'state', 'city', 'area', 'outlet_name', 'sku_basket', 'sales_units',
      'spins_recorded', 'handed_over', 'pending', 'handed_over_cost', 'sale_status', 'data_check', 'transaction_id'],
    spins: ['spin_id', 'spin_date', 'spin_time', 'promoter_name', 'state', 'city', 'area', 'outlet_name', 'prize_name', 'prize_cost',
      'redemption_status', 'distribution_version', 'distribution_mode', 'config_version', 'handover_date', 'handover_time', 'transaction_id', 'spin_no'],
    skus: ['bill_date', 'promoter_name', 'state', 'city', 'area', 'outlet_name', 'sku_code', 'product_name', 'sales_units', 'sale_status', 'data_check', 'transaction_id'],
  };
  const columns = screenKeys[view].map(key => selected.columns.find(c => c.key === key)).map(c => c.key === 'redemption_status'
    ? { ...c, render: r => <Badge tone={tone[r.redemption_status]}>{r.redemption_status?.replaceAll('_', ' ') || 'Not recorded'}</Badge> }
    : c.key === 'data_check' ? { ...c, render: r => <Badge tone={r.data_check === 'OK' ? 'green' : 'amber'}>{r.data_check}</Badge> }
      : { ...c, ...(moneyKeys.has(c.key) ? { align: 'r', fmt: fmt.inr2 } : countKeys.has(c.key) ? { align: 'r' } : {}) });
  return (
    <div className="s-page transactions-report">
      <FilterBar data={data} filters={filters} setFilters={setFilters} />
      <p className="txn-note">The date range selects bill dates. Spin and handover timestamps are shown separately in India time.
        {filters.product_id && ' Bills and Spins include bills containing the selected SKU. SKU Sales includes only the selected SKU.'}</p>
      <Panel title="Transactions" actions={<>
        <button className="s-btn ghost sm" disabled={report.loading || busy} onClick={() => setRefresh(n => n + 1)}>Refresh report</button>
        <button className="s-btn sm" disabled={!result || busy} onClick={downloadExcel}>{busy ? 'Preparing Excel…' : 'Download Excel — all 3 sheets'}</button>
      </>}>
        {exportError && <div className="s-err" role="alert">{exportError}</div>}
        {!result ? <Loading state={report} /> : <>
          <div className="txn-kpis">
            <Kpi label="Bills" value={fmt.num(result.summary.bills)} />
            <Kpi label="Recorded units · excl. cancelled" value={fmt.num(result.summary.units)} />
            <Kpi label="Recorded spins" value={fmt.num(result.summary.spins)} />
            <Kpi label="Prizes handed over" value={fmt.num(result.summary.handed_over)} />
            <Kpi label="Handed-over prize cost" value={fmt.inr(result.summary.handed_over_cost)} />
          </div>
          {result.summary.checks > 0 && <p className="txn-review" role="status">{result.summary.checks} bill(s) need a data check. See the Data Check column; refresh if activity changed while loading.</p>}
          <Tabs tabs={REPORT_VIEWS} value={view} onChange={setView} />
          <div className="txn-downloads">
            {REPORT_VIEWS.map(v => <button className="s-btn ghost sm" key={v.key} onClick={() => exportCSV(result[v.key], v.columns,
              `transactions_${v.key}_${filters.date_from || 'all'}_${filters.date_to || ''}`)}>CSV — {v.label}</button>)}
          </div>
          <p className="txn-note">{view === 'bills' ? 'One row per bill. Bill units are counted once. Cancelled bills remain visible and contribute zero recorded units.'
            : view === 'spins' ? 'One row per recorded spin. Each prize is shown once. Sales quantities and SKU baskets belong to the Bills and SKU Sales views.'
              : 'One row per bill and SKU. SKU units are counted once; prizes are not assigned to individual SKU lines.'}</p>
          {filters.product_id && <p className="txn-note">Selected SKU units: <b>{fmt.num(result.summary.sku_units)}</b>. The bill-unit total above covers the entire matching baskets.</p>}
          <p className="txn-note">{result[view].length > 300 ? `Showing the latest 300 of ${fmt.num(result[view].length)} rows. Downloads contain all matching rows and detailed columns.`
            : `${fmt.num(result[view].length)} matching rows. Downloads contain all matching rows and detailed columns.`}</p>
          <div className={`txn-table txn-table-${view}`}><DataTable key={view} rows={result[view].slice(0, 300)} columns={columns} maxHeight="65vh" /></div>
          <p className="txn-note txn-asof">Loaded {fmt.dt(result.read_at || result.as_of)}. New bills/spins after the load cutoff require Refresh report. Handover statuses reflect when their page was read.</p>
        </>}
      </Panel>
    </div>
  );
}
