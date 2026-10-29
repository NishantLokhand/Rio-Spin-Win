import React, { useState } from 'react';
import { rpc, selectAll } from '../lib/api.js';
import { userPerformanceColumns, dailyUserColumns } from '../lib/userReportColumns.js';
import { loadUserActivityData } from '../lib/userActivityData.js';
import { completeUserPerformance } from '../lib/userPerformance.js';
import { istToday } from '../lib/store.js';
import FilterBar from './FilterBar.jsx';
import SpinHistory from './SpinHistory.jsx';
import V7ExpiryReport from './V7ExpiryReport.jsx';
import V8SpeakerReport from './V8SpeakerReport.jsx';
import ZeroSpinDownload from './ZeroSpinDownload.jsx';
import { reportTotal, reportPeriod } from '../lib/reportTotals.js';
import { useAsync, Panel, Loading, DataTable, Tabs, BarList, Kpi, fmt } from './ui.jsx';

const money = { align: 'r', fmt: fmt.inr };
const COLS = {
  user: [...userPerformanceColumns, { key: 'account_status', label: 'Account Status' }, { key: 'activity', label: 'Activity' }],
  date: dailyUserColumns,
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

function ReportOverview({ rows, tab, userDaily }) {
  const prize = tab === 'prize';
  const spins = prize ? rows.reduce((n, r) => n + Number(r.quantity || 0), 0) : rows.reduce((n, r) => n + Number(r.spins || 0), 0);
  const units = prize ? 0 : rows.reduce((n, r) => n + Number(r.units || 0), 0);
  const cost = prize ? rows.reduce((n, r) => n + Number(r.total_cost || 0), 0) : rows.reduce((n, r) => n + Number(r.giveaway_cost || 0), 0);
  const activeRows = rows.filter((r) => Number(r.spins || 0) > 0).length;
  const inactiveRows = userDaily ? rows.filter((r) => Number(r.spins || 0) === 0).length : 0;
  const people = new Set(rows.map((r) => r.key).filter(Boolean)).size;
  const outlets = new Set(rows.map((r) => r.outlet_code || r.key).filter(Boolean)).size;
  const avg = spins ? cost / spins : 0;
  return (
    <div className="kpis report-overview" aria-label="Report summary">
      <Kpi label={prize ? 'Prize types' : userDaily ? 'Users' : 'Rows'} value={fmt.num(prize ? rows.length : userDaily ? people : rows.length)} />
      <Kpi label="Spins" value={fmt.num(spins)} />
      {!prize && <Kpi label="Units sold" value={fmt.num(units)} />}
      <Kpi label="Giveaway cost" value={fmt.inr(cost)} />
      <Kpi label="Average cost / spin" value={fmt.inr2(avg)} />
      {userDaily && <Kpi label="Active user-days" value={fmt.num(activeRows)} tone="good" />}
      {userDaily && <Kpi label="Inactive user-days" value={fmt.num(inactiveRows)} tone={inactiveRows ? 'warn' : 'good'} />}
      {!userDaily && tab === 'outlet' && <Kpi label="Outlets" value={fmt.num(outlets)} />}
    </div>
  );
}

const TABS = [
  { key: 'user', label: 'User Performance' },
  { key: 'outlet', label: 'Outlet Performance' }, { key: 'prize', label: 'Prize Usage' },
  { key: 'product', label: 'SKU' }, { key: 'state', label: 'State' }, { key: 'territory', label: 'Territory' }, { key: 'city', label: 'City' },
  { key: 'area', label: 'Area' }, { key: 'distributor', label: 'Distributor' }, { key: 'date', label: 'Daily User Performance' },
];

export default function Reports({ data, filters, setFilters }) {
  const [tab, setTab] = useState('user');
  const [userType, setUserType] = useState('');
  const userDaily = tab === 'user' || tab === 'date';
  const people = useAsync(() => selectAll('org_people', 'auth_user_id,designation', (q) => q.not('auth_user_id', 'is', null)), []);
  const rep = useAsync(() => tab === 'prize'
    ? rpc('prize_distribution_report', { p_filters: filters })
    : userDaily ? Promise.all([
      loadUserActivityData(),
      rpc('report_user_daily', { p_filters: filters, p_user_type: userType || null }),
      tab === 'user' ? rpc('report_user_prize_breakdown', { p_date_from: filters.date_from || null, p_date_to: filters.date_to || null }) : Promise.resolve([]),
    ]).then(([source, rows, breakdown]) => completeUserPerformance(source, rows, filters, userType, istToday(),
      new Map((breakdown || []).map((r) => [r.user_id, [
        Number(r.snack5 || 0) ? '₹5 Snack: ' + r.snack5 : '',
        Number(r.snack10 || 0) ? '₹10 Snack: ' + r.snack10 : '',
        Number(r.shades || 0) ? 'Rio Shades: ' + r.shades : '',
        Number(r.other || 0) ? 'Other: ' + r.other : '',
      ].filter(Boolean).join(' · ')]))))
    : rpc('report_summary', { p_group: tab, p_filters: filters }), [tab, userType, JSON.stringify(filters)]);
  const cols = COLS[tab] || generic(TABS.find((t) => t.key === tab).label);
  const drill = tab === 'area' ? (r) => { setFilters({ ...filters, area: r.key }); setTab('outlet'); }
    : tab === 'user' ? (r) => { setFilters({ ...filters, promoter_id: r.key, date_from: r.date, date_to: r.date }); setTab('outlet'); }
    : tab === 'territory' ? (r) => { setFilters({ ...filters, territory_id: r.key }); setTab('user'); }
    : tab === 'state' ? (r) => { setFilters({ ...filters, state_id: r.key }); setTab('territory'); } : undefined;

  const totals = rep.data && tab !== 'prize' ? rep.data.reduce((a, r) => ({
    spins: a.spins + Number(r.spins || 0), units: a.units + Number(r.units || 0), cost: a.cost + Number(r.giveaway_cost || 0),
  }), { spins: 0, units: 0, cost: 0 }) : null;
  const prizeTotals = tab === 'prize' && rep.data?.length ? {
    spins: Number(rep.data[0].total_spins || 0), cost: Number(rep.data[0].giveaway_cost || 0),
    avg: Number(rep.data[0].avg_giveaway_cost || 0),
  } : null;
  const reportRows = rep.data || [];
  const totalRow = reportTotal(reportRows, tab === 'prize');
  const promoterCount = new Set(reportRows.map((row) => row.key)).size;
  if (userDaily) totalRow.label = `TOTAL (${promoterCount} users)`;
  const exportRows = [...reportRows, totalRow].map((row) => ({ ...row,
    date_from: filters.date_from || 'Beginning', date_to: filters.date_to || 'No end date' }));
  const exportColumns = tab === 'date' ? cols : [{ key: 'date_from', label: 'Date From' }, { key: 'date_to', label: 'Date To' }, ...cols];

  return (
    <div className="s-page">
      <FilterBar data={data} filters={filters} setFilters={setFilters}
        userPerformance={userDaily} userType={userType} setUserType={setUserType} userPeople={people.data || []} />
      <div className="pad row-actions"><ZeroSpinDownload users={data.promoters} dates={filters} userType={userType} userId={filters.promoter_id} /><SpinHistory filters={filters} userType={userType} /><V7ExpiryReport /><V8SpeakerReport /></div>
      <Tabs tabs={TABS} value={tab} onChange={setTab} />
      <Panel title={TABS.find((t) => t.key === tab).label}
             actions={totals
               ? <span className="muted">Total: {userDaily && `${fmt.num(promoterCount)} users · `}{fmt.num(totals.spins)} spins · {fmt.num(totals.units)} units · {fmt.inr(totals.cost)} · avg {fmt.inr2(totals.spins ? totals.cost / totals.spins : 0)}</span>
               : prizeTotals && <span className="muted">Total: {fmt.num(prizeTotals.spins)} spins · {fmt.inr(prizeTotals.cost)} giveaway cost · avg {fmt.inr2(prizeTotals.avg)} / spin</span>}>
        {!rep.data ? <Loading state={rep} /> : (
          <>
            <p className="muted pad">Report period: <strong>{reportPeriod(filters)}</strong></p>
            {tab === 'date' && <p className="muted pad">One row per user per date, including zero-spin users. No-activity locations come from the user profile; no visits are invented. Campaign, Territory, TSE, Outlet, Distributor and SKU filters show recorded activity only. Spin times are in India time for the entire business day; activity span includes gaps and is shown to whole minutes. Snack used percentages are current stock usage, not historical daily usage.</p>}
            {tab === 'user' && <p className="muted pad">Activity % uses calendar days from account creation within the selected period, through yesterday. Stock used % is current stock received minus current balance, divided by stock received; it includes other stock reductions. Blank percentages mean no usable stock baseline.</p>}
            {tab === 'user' && <p className="muted pad">Includes disabled accounts and zero-spin dates from account creation. Today is in progress. Dates without recorded activity use profile State/City/Area and have no visited outlets. Campaign, Territory, TSE, Outlet, Distributor or SKU filters show recorded activity only.</p>}
            {tab === 'user' && <p className="muted pad">First/last spin times are in India time and cover the user’s entire business day, even when outlet or SKU filters are selected. Activity span is last minus first, shown to whole minutes including gaps; it is not verified working time.</p>}
            {tab === 'prize' && rep.data.length > 0 && (
              <div className="pad"><BarList rows={rep.data} labelKey="label" valueKey="pct" format={fmt.pct} sub={(r) => `${fmt.num(r.quantity)} won`} /></div>
            )}
            <ReportOverview rows={reportRows} tab={tab} userDaily={userDaily} />
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
