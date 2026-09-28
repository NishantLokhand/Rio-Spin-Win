import React, { useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { selectAll } from '../lib/api.js';
import { exportCSV, exportXLSX } from '../lib/exporter.js';
import FilterBar from './FilterBar.jsx';
import { useAsync, Panel, Loading, DataTable, Badge, fmt } from './ui.jsx';

export const TXN_COLUMNS = [
  { key: 'transaction_id', label: 'Transaction ID' }, { key: 'spin_id', label: 'Spin ID' }, { key: 'campaign_code', label: 'Campaign' },
  { key: 'date', label: 'Date' }, { key: 'time', label: 'Time' }, { key: 'state', label: 'State' }, { key: 'territory', label: 'Territory' },
  { key: 'tse_code', label: 'TSE Code' }, { key: 'tse_name', label: 'TSE Name' }, { key: 'outlet_code', label: 'Outlet Code' },
  { key: 'outlet_name', label: 'Outlet Name' }, { key: 'city', label: 'City' }, { key: 'distributor', label: 'Distributor' },
  { key: 'promoter_code', label: 'Promoter ID' }, { key: 'promoter_name', label: 'Promoter Name' }, { key: 'promoter_type', label: 'Promoter Type' },
  { key: 'sku_code', label: 'SKU Code' }, { key: 'sku', label: 'SKU' }, { key: 'quantity', label: 'Quantity' },
  { key: 'prize_name', label: 'Prize' }, { key: 'prize_cost', label: 'Prize Cost' }, { key: 'substituted', label: 'Substituted' },
  { key: 'redemption_status', label: 'Redemption Status' }, { key: 'inventory_status', label: 'Inventory Status' },
  { key: 'sale_status', label: 'Sale Status' }, { key: 'device_ref', label: 'Device Ref' }, { key: 'config_version', label: 'Prize Config Version' },
];

export function applyTxnFilters(q, f) {
  if (f.date_from) q = q.gte('date', f.date_from);
  if (f.date_to) q = q.lte('date', f.date_to);
  for (const k of ['campaign_id', 'state_id', 'territory_id', 'tse_id', 'outlet_id', 'promoter_id', 'product_id', 'city', 'distributor']) {
    if (f[k]) q = q.eq(k, f[k]);
  }
  return q;
}

export default function Transactions({ data, filters, setFilters }) {
  const [busy, setBusy] = useState(false);
  const list = useAsync(async () => {
    let q = supabase.from('v_transactions').select('*').order('spun_at', { ascending: false, nullsFirst: false }).limit(300);
    q = applyTxnFilters(q, filters);
    const { data: rows, error } = await q;
    if (error) throw error;
    return rows;
  }, [JSON.stringify(filters)]);

  async function exportAll(kind) {
    setBusy(true);
    try {
      const rows = await selectAll('v_transactions', '*', (q) => applyTxnFilters(q, filters).order('spun_at', { ascending: false }));
      (kind === 'csv' ? exportCSV : exportXLSX)(rows, TXN_COLUMNS, `transactions_${filters.date_from || 'all'}_${filters.date_to || ''}`);
    } finally { setBusy(false); }
  }

  const tone = { handed_over: 'green', pending: 'amber', not_redeemed: 'red' };
  return (
    <div className="s-page">
      <FilterBar data={data} filters={filters} setFilters={setFilters} />
      <Panel title="Transactions (latest 300 shown)" actions={<>
        <button className="s-btn sm" disabled={busy} onClick={() => exportAll('csv')}>Export all CSV</button>
        <button className="s-btn sm" disabled={busy} onClick={() => exportAll('xlsx')}>Export all Excel</button>
      </>}>
        {!list.data ? <Loading state={list} /> : (
          <DataTable rows={list.data} maxHeight="70vh" columns={[
            { key: 'spin_id', label: 'Spin ID' },
            { key: 'date', label: 'Date', fmt: fmt.date }, { key: 'time', label: 'Time' },
            { key: 'outlet_name', label: 'Outlet' }, { key: 'tse_name', label: 'TSE' }, { key: 'promoter_name', label: 'Promoter' },
            { key: 'sku', label: 'SKU' }, { key: 'quantity', label: 'Qty', align: 'r' },
            { key: 'prize_name', label: 'Prize' }, { key: 'prize_cost', label: 'Cost', align: 'r', fmt: fmt.inr },
            { key: 'redemption_status', label: 'Status', render: (r) => r.redemption_status
                ? <Badge tone={tone[r.redemption_status]}>{r.redemption_status.replace('_', ' ')}</Badge>
                : <Badge>{r.sale_status}</Badge> },
          ]} />
        )}
      </Panel>
    </div>
  );
}
