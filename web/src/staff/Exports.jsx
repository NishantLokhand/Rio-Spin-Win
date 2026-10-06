import React, { useState } from 'react';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { exportCSV, exportXLSX } from '../lib/exporter.js';
import FilterBar from './FilterBar.jsx';
import { Panel } from './ui.jsx';
import { TXN_COLUMNS, applyTxnFilters } from './Transactions.jsx';

const report = (group) => async (f) => rpc('report_summary', { p_group: group, p_filters: f });

export default function Exports({ data, filters, setFilters }) {
  const [busy, setBusy] = useState('');
  const [err, setErr] = useState('');
  const prizes = Object.fromEntries(data.masters.prizes.map((p) => [p.id, p.name]));
  const users = Object.fromEntries(data.promoters.map((u) => [u.id, u.full_name]));

  const ITEMS = [
    { key: 'transactions', label: 'Transactions / spins', uses: true, run: (f) => selectAll('v_transactions', '*', (q) => applyTxnFilters(q, f).order('spun_at')), cols: TXN_COLUMNS },
    { key: 'promoter_performance', label: 'Promoter performance', uses: true, run: report('promoter') },
    { key: 'tse_performance', label: 'TSE performance', uses: true, run: report('tse') },
    { key: 'outlet_performance', label: 'Outlet performance', uses: true, run: report('outlet') },
    { key: 'prize_usage', label: 'Prize usage', uses: true, run: report('prize') },
    { key: 'campaign_spend_daily', label: 'Campaign spend (daily)', uses: true, run: report('date') },
    { key: 'sku_performance', label: 'SKU performance', uses: true, run: report('product') },
    { key: 'inventory_balances', label: 'Inventory — current balances', run: async () => (await selectAll('promoter_inventory', '*'))
        .map((i) => ({ promoter: users[i.promoter_id], prize: prizes[i.prize_id], on_hand: i.on_hand, reserved_pending_handover: i.reserved, updated_at: i.updated_at })) },
    { key: 'inventory_movements', label: 'Inventory — movement log', run: async () => (await selectAll('inventory_movements', '*', (q) => q.order('created_at')))
        .map((m) => ({ date_time: m.created_at, promoter: users[m.promoter_id], prize: prizes[m.prize_id], type: m.movement_type, qty: m.qty,
          stock_after: m.on_hand_after, issued_by: m.performed_by, reference: m.reference, note: m.note })) },
    { key: 'outlet_master', label: 'Outlet master', run: async () => data.outletsFull.map((o) => {
        const t = data.masters.tses.find((x) => x.id === o.tse_id); const tr = data.masters.territories.find((x) => x.id === (o.territory_id || t?.territory_id));
        return { state: data.masters.states.find((s) => s.id === (o.state_id || tr?.state_id))?.name, territory: tr?.name, tse_code: t?.code, tse_name: t?.name,
          outlet_code: o.outlet_code, outlet_name: o.name, area: o.area, city: o.city, distributor: o.distributor, status: o.status };
      }) },
  ];

  async function go(item, kind) {
    setBusy(item.key + kind); setErr('');
    try {
      const rows = await item.run(filters);
      if (!rows.length) throw new Error('No rows for the selected filters');
      (kind === 'csv' ? exportCSV : exportXLSX)(rows, item.cols || null, `${item.key}_${filters.date_from || 'all'}`);
    } catch (e) { setErr(friendly(e)); } finally { setBusy(''); }
  }

  return (
    <div className="s-page">
      <FilterBar data={data} filters={filters} setFilters={setFilters} />
      {err && <div className="s-err">{err}</div>}
      <Panel title="Export data">
        <div className="export-list">
          {ITEMS.map((it) => (
            <div key={it.key} className="export-row">
              <div><b>{it.label}</b><small>{it.uses ? 'Uses the filters above' : 'Full current data'}</small></div>
              <button className="s-btn ghost sm" disabled={!!busy} onClick={() => go(it, 'csv')}>{busy === it.key + 'csv' ? '…' : 'CSV'}</button>
              <button className="s-btn sm" disabled={!!busy} onClick={() => go(it, 'xlsx')}>{busy === it.key + 'xlsx' ? '…' : 'Excel'}</button>
            </div>
          ))}
        </div>
      </Panel>
    </div>
  );
}
