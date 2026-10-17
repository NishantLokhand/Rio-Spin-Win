import React, { useState } from 'react';
import { rpc } from '../lib/api.js';
import FilterBar from './FilterBar.jsx';
import ZeroSpinDownload from './ZeroSpinDownload.jsx';
import { reportTotal, reportPeriod } from '../lib/reportTotals.js';
import { useAsync, Panel, Loading, DataTable, Tabs, BarList, fmt } from './ui.jsx';

const money = { align: 'r', fmt: fmt.inr };
const COLS = {
  tse: [
    { key: 'label', label: 'TSE' }, { key: 'tse_code', label: 'TSE Code' }, { key: 'territory', label: 'Territory' },
    { key: 'active_outlets', label: 'Active Outlets', align: 'r' }, { key: 'promoters', label: 'Promoters Deployed', align: 'r' },
    { key: 'spins', label: 'Spins', align: 'r', fmt: fmt.num }, { key: 'units', label: 'Units Sold', align: 'r', fmt: fmt.num },
    { key: 'giveaway_cost', label: 'Giveaway Cost', ...money }, { key: 'avg_cost', label: 'Average Giveaway Cost', align: 'r', fmt: fmt.inr2 },
  ],
  promoter: [
    { key: 'label', label: 'Promoter' }, { key: 'promoter_code', label: 'Code' }, { key: 'promoter_type', label: 'Type' },
    { key: 'state', label: 'State' }, { key: 'territory', label: 'Territory' }, { key: 'city', label: 'City' },
    { key: 'active_outlets', label: 'Outlets Covered', align: 'r' },
    { key: 'spins', label: 'Spins', align: 'r', fmt: fmt.num }, { key: 'units', label: 'Units Sold', align: 'r', fmt: fmt.num },
    { key: 'giveaway_cost', label: 'Giveaway Cost', ...money }, { key: 'avg_cost', label: 'Average Cost', align: 'r', fmt: fmt.inr2 },
  ],
  outlet: [
    { key: 'label', label: 'Outlet' }, { key: 'outlet_code', label: 'Outlet Code' }, { key: 'area', label: 'Area' },
    { key: 'tse', label: 'TSE' }, { key: 'territory', label: 'Territory' },
    { key: 'spins', label: 'Spins', align: 'r', fmt: fmt.num }, { key: 'units', label: 'Units Sold', align: 'r', fmt: fmt.num },
    { key: 'giveaway_cost', label: 'Giveaway Cost', ...money }, { key: 'avg_cost', label: 'Average Giveaway Cost', align: 'r', fmt: fmt.inr2 },
  ],
  prize: [
    { key: 'label', label: 'Prize' }, { key: 'quantity', label: 'Quantity Won', align: 'r', fmt: fmt.num },
    { key: 'unit_cost', label: 'Cost Per Prize', ...money }, { key: 'total_cost', label: 'Total Cost', ...money },
    { key: 'target_pct', label: 'Target Share', align: 'r', fmt: fmt.pct },
    { key: 'pct', label: 'Actual Share', align: 'r', fmt: fmt.pct },
    { key: 'variance_pct', label: 'Variance', align: 'r', fmt: fmt.pct },
    { key: 'handed_over', label: 'Handed Over', align: 'r' },
    { key: 'pending', label: 'Pending', align: 'r' },
  ],
};
const generic = (label) => [
  { key: 'label', label }, { key: 'sales', label: 'Sales', align: 'r', fmt: fmt.num },
  { key: 'spins', label: 'Spins', align: 'r', fmt: fmt.num }, { key: 'units', label: 'Units Sold', align: 'r', fmt: fmt.num },
  { key: 'active_outlets', label: 'Outlets', align: 'r' }, { key: 'promoters', label: 'Promoters', align: 'r' },
  { key: 'giveaway_cost', label: 'Giveaway Cost', ...money }, { key: 'avg_cost', label: 'Avg Cost', align: 'r', fmt: fmt.inr2 },
];

const TABS = [
  { key: 'tse', label: 'TSE Performance' }, { key: 'promoter', label: 'Promoter Performance' },
  { key: 'outlet', label: 'Outlet Performance' }, { key: 'prize', label: 'Prize Usage' },
  { key: 'product', label: 'SKU' }, { key: 'state', label: 'State' }, { key: 'territory', label: 'Territory' }, { key: 'city', label: 'City' },
  { key: 'area', label: 'Area' }, { key: 'city', label: 'City' }, { key: 'distributor', label: 'Distributor' }, { key: 'date', label: 'Daily' },
];

export default function Reports({ data, filters, setFilters }) {
  const [tab, setTab] = useState('tse');
  const rep = useAsync(() => tab === 'prize'
    ? rpc('prize_distribution_report', { p_filters: filters })
    : rpc('report_summary', { p_group: tab, p_filters: filters }), [tab, JSON.stringify(filters)]);
  const cols = COLS[tab] || generic(TABS.find((t) => t.key === tab).label);
  const drill = tab === 'area' ? (r) => { setFilters({ ...filters, area: r.key }); setTab('outlet'); }
    : tab === 'tse' ? (r) => { setFilters({ ...filters, tse_id: r.key }); setTab('outlet'); }
    : tab === 'territory' ? (r) => { setFilters({ ...filters, territory_id: r.key }); setTab('tse'); }
    : tab === 'state' ? (r) => { setFilters({ ...filters, state_id: r.key }); setTab('territory'); } : undefined;

  const totals = rep.data && tab !== 'prize' ? rep.data.reduce((a, r) => ({
    spins: a.spins + Number(r.spins || 0), units: a.units + Number(r.units || 0), cost: a.cost + Number(r.giveaway_cost || 0),
  }), { spins: 0, units: 0, cost: 0 }) : null;
  const prizeTotals = tab === 'prize' && rep.data?.length ? {
    spins: Number(rep.data[0].total_spins || 0), cost: Number(rep.data[0].giveaway_cost || 0),
    avg: Number(rep.data[0].avg_giveaway_cost || 0),
  } : null;
  const reportRows = tab === 'date' ? [...(rep.data || [])].sort((a, b) => String(b.key).localeCompare(String(a.key))) : rep.data || [];
  const totalRow = reportTotal(reportRows, tab === 'prize');
  const exportRows = [...reportRows, totalRow].map((row) => ({ ...row,
    date_from: filters.date_from || 'Beginning', date_to: filters.date_to || 'No end date' }));
  const exportColumns = [{ key: 'date_from', label: 'Date From' }, { key: 'date_to', label: 'Date To' }, ...cols];

  return (
    <div className="s-page">
      <FilterBar data={data} filters={filters} setFilters={setFilters} />
      <div className="pad"><ZeroSpinDownload users={data.promoters} dates={filters} /></div>
      <Tabs tabs={TABS} value={tab} onChange={setTab} />
      <Panel title={TABS.find((t) => t.key === tab).label}
             actions={totals
               ? <span className="muted">Total: {fmt.num(totals.spins)} spins · {fmt.num(totals.units)} units · {fmt.inr(totals.cost)} · avg {fmt.inr2(totals.spins ? totals.cost / totals.spins : 0)}</span>
               : prizeTotals && <span className="muted">Total: {fmt.num(prizeTotals.spins)} spins · {fmt.inr(prizeTotals.cost)} giveaway cost · avg {fmt.inr2(prizeTotals.avg)} / spin</span>}>
        {!rep.data ? <Loading state={rep} /> : (
          <>
            <p className="muted pad">Report period: <strong>{reportPeriod(filters)}</strong></p>
            {tab === 'prize' && rep.data.length > 0 && (
              <div className="pad"><BarList rows={rep.data} labelKey="label" valueKey="pct" format={fmt.pct} sub={(r) => `${fmt.num(r.quantity)} won`} /></div>
            )}
            <DataTable rows={reportRows} columns={cols} exportRows={exportRows} exportColumns={exportColumns}
                       exportName={`${tab}_report_${filters.date_from || 'beginning'}_${filters.date_to || 'all'}`} onRowClick={drill}
                       footer={<tfoot><tr>{cols.map((c) => <th key={c.key} className={c.align === 'r' ? 'r' : ''}>
                         {totalRow[c.key] == null ? '' : c.fmt ? c.fmt(totalRow[c.key], totalRow) : totalRow[c.key]}
                       </th>)}</tr></tfoot>} />
            {drill && <small className="muted">Click a row to drill down.</small>}
          </>
        )}
      </Panel>
    </div>
  );
}
