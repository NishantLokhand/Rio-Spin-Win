import React, { useState } from 'react';
import { rpc, friendly } from '../lib/api.js';
import FilterBar from './FilterBar.jsx';
import { useAsync, Kpi, Panel, Loading, DataTable, BarList, ColumnChart, Modal, Field, fmt } from './ui.jsx';

const LEVELS = [
  { group: 'state', label: 'State', filter: 'state_id' },
  { group: 'territory', label: 'Territory', filter: 'territory_id' },
  { group: 'tse', label: 'TSE', filter: 'tse_id' },
  { group: 'outlet', label: 'Outlet', filter: 'outlet_id' },
  { group: 'promoter', label: 'Promoter', filter: 'promoter_id' },
];

export default function Dashboard({ data, filters, setFilters, go }) {
  const key = JSON.stringify(filters);
  const k = useAsync(() => rpc('dashboard_kpis', { p_filters: filters }), [key]);
  const trendFilters = filters.date_from === filters.date_to ? { ...filters, date_from: undefined } : filters;
  const trend = useAsync(() => rpc('report_summary', { p_group: 'date', p_filters: trendFilters }), [JSON.stringify(trendFilters)]);
  const [path, setPath] = useState([]);   // drill-down breadcrumb [{level, key, label}]
  const [bulkReplenishOpen, setBulkReplenishOpen] = useState(false);
  const level = LEVELS[Math.min(path.length, LEVELS.length - 1)];
  const drillFilters = { ...filters, ...Object.fromEntries(path.map((p) => [LEVELS[p.level].filter, p.key])) };
  const drill = useAsync(() => rpc('report_summary', { p_group: level.group, p_filters: drillFilters }), [JSON.stringify(drillFilters), level.group]);

  const K = k.data;
  const t = K?.totals || {};
  const prizeCount = (code) => K?.prizes?.find((p) => p.tier === code)?.count ?? 0;
  const b = K?.budget;

  return (
    <div className="s-page">
      <FilterBar data={data} filters={filters} setFilters={setFilters} />
      {!K ? <Loading state={k} /> : (
        <>
          <div className="kpis">
            <Kpi label="Spins" value={fmt.num(t.spins)} />
            <Kpi label="Promotional sales" value={fmt.num(t.sales)} sub={`${fmt.num(t.units)} units sold`} />
            <Kpi label="Giveaway spend" value={fmt.inr(t.giveaway_cost)} />
            <Kpi label="Avg cost / spin" value={fmt.inr2(t.avg_cost)} tone={t.avg_cost > (b?.target ?? 10) ? 'warn' : 'good'}
                 sub={`Target ${fmt.inr2(b?.target ?? 10)}`} />
            <Kpi label="Active promoters" value={fmt.num(t.active_promoters)} sub={`${K.promoters_on_duty} on duty today`} />
            <Kpi label="Active outlets" value={fmt.num(t.active_outlets)} />
            <Kpi label="Rio Dare issued" value={fmt.num(prizeCount('mid'))} />
            <Kpi label="Sunglasses issued" value={fmt.num(prizeCount('high'))} />
            <Kpi label="Speakers issued" value={fmt.num(prizeCount('jackpot'))} tone="accent" />
            <Kpi label="Low-stock alerts" value={fmt.num(K.low_stock.length)} tone={K.low_stock.length ? 'warn' : ''} />
            <Kpi label="Flagged activity" value={fmt.num(K.open_flags)} tone={K.open_flags ? 'bad' : ''} />
            <Kpi label="Pending handovers" value={fmt.num(K.pending_handovers)} tone={K.pending_handovers ? 'warn' : ''} />
          </div>

          <div className="grid2">
            {b && (
              <Panel title={`Budget — ${b.campaign}`}>
                <div className="budget">
                  <div className="budget-row"><span>Campaign budget</span><b>{fmt.inr(b.total_budget)}</b></div>
                  <div className="budget-row"><span>Used</span><b>{fmt.inr(b.used)}</b></div>
                  <div className="budget-row"><span>Remaining</span><b>{fmt.inr(b.remaining)}</b></div>
                  {b.total_budget && <div className="meter"><div style={{ width: `${Math.min(100, (b.used / b.total_budget) * 100)}%` }} /></div>}
                  <div className="budget-row"><span>Est. spins remaining</span><b>{fmt.num(b.est_spins_remaining)}</b></div>
                  <small className="muted">at current average {fmt.inr2(b.avg_cost)} per spin</small>
                  {b.daily_budget && <div className="budget-row"><span>Today</span><b>{fmt.inr(b.used_today)} / {fmt.inr(b.daily_budget)}</b></div>}
                  {(b.state_budgets || []).map((s) => (
                    <div className="budget-row" key={s.state}><span>{s.state}</span><b>{fmt.inr(s.used)} / {fmt.inr(s.budget)}</b></div>
                  ))}
                </div>
              </Panel>
            )}
            <Panel title="Prizes issued">
              <BarList rows={K.prizes} labelKey="short_name" valueKey="count" format={fmt.num} sub={(r) => fmt.inr(r.cost)} />
            </Panel>
          </div>

          <div className="grid2">
            <Panel title="Spins per day">
              {trend.data?.length ? (
                <ColumnChart rows={[...trend.data].sort((a, b2) => String(a.key).localeCompare(String(b2.key)))} xKey="key" yKey="spins"
                             format={fmt.num} xFormat={fmt.date} />
              ) : <div className="muted pad">No spins in range</div>}
            </Panel>
            <Panel title="Current prize inventory (with promoters)">
              <DataTable rows={K.stock} columns={[
                { key: 'short_name', label: 'Prize' },
                { key: 'on_hand', label: 'On hand', align: 'r', fmt: fmt.num },
                { key: 'reserved', label: 'Awaiting handover', align: 'r', fmt: fmt.num },
              ]} />
              {K.low_stock.length > 0 && (
                <div className="lowstock">
                  <b>LOW STOCK ALERTS</b>
                  {K.low_stock.slice(0, 8).map((l, i) => <div key={i}>{l.promoter}: <b>{l.prize}</b> — only {l.on_hand} remaining</div>)}
                  <div className="row-actions">
                    {data.role === 'admin' && <button className="s-btn sm" onClick={() => setBulkReplenishOpen(true)}>Bulk Replenish</button>}
                    <button className="s-btn ghost sm" onClick={() => go('promoters')}>Replenish stock →</button>
                  </div>
                </div>
              )}
            </Panel>
          </div>

          {bulkReplenishOpen && <BulkReplenishModal
            lowStock={K.low_stock}
            prizes={data.masters.prizes}
            onClose={(changed) => { setBulkReplenishOpen(false); if (changed) k.reload(); }}
          />}

          <Panel title="Drill-down" actions={
            <div className="crumbs-s">
              <button onClick={() => setPath([])}>All</button>
              {path.map((p, i) => <button key={i} onClick={() => setPath(path.slice(0, i + 1))}>› {p.label}</button>)}
            </div>}>
            {!drill.data ? <Loading state={drill} /> : (
              <DataTable rows={drill.data} exportName={`drilldown_${level.group}`}
                onRowClick={path.length < LEVELS.length - 1 ? (r) => setPath([...path, { level: path.length, key: r.key, label: r.label }]) : undefined}
                columns={[
                  { key: 'label', label: level.label },
                  ...(level.group === 'outlet' ? [{ key: 'outlet_code', label: 'Code' }] : []),
                  { key: 'spins', label: 'Spins', align: 'r', fmt: fmt.num },
                  { key: 'sales', label: 'Sales', align: 'r', fmt: fmt.num },
                  { key: 'units', label: 'Units', align: 'r', fmt: fmt.num },
                  { key: 'giveaway_cost', label: 'Giveaway', align: 'r', fmt: fmt.inr },
                  { key: 'avg_cost', label: 'Avg/spin', align: 'r', fmt: fmt.inr2 },
                  { key: 'active_outlets', label: 'Outlets', align: 'r' },
                  { key: 'promoters', label: 'Promoters', align: 'r' },
                ]} />
            )}
            {path.length < LEVELS.length - 1 && <small className="muted">Click a row to drill into {LEVELS[path.length + 1].label}</small>}
          </Panel>
        </>
      )}
    </div>
  );
}

function BulkReplenishModal({ lowStock, prizes, onClose }) {
  const people = new Map();
  lowStock.forEach((row) => {
    const person = people.get(row.promoter_id) || { id: row.promoter_id, name: row.promoter, alerts: [] };
    person.alerts.push(row);
    people.set(row.promoter_id, person);
  });
  const targets = [...people.values()];
  const prizeIds = [...new Set(lowStock.map((row) => row.prize_id).filter(Boolean))];
  const targetPrizes = prizeIds.map((id) => prizes.find((prize) => prize.id === id)).filter(Boolean);
  const [quantities, setQuantities] = useState({});
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const recipientCount = targets.filter((person) => person.alerts.some((alert) => Number(quantities[alert.prize_id]) > 0)).length;

  async function save() {
    const entered = Object.entries(quantities).filter(([, value]) => Number(value) > 0);
    if (!entered.length || entered.some(([, value]) => !Number.isInteger(Number(value)))) {
      setError('Enter a whole-number quantity for at least one prize.');
      return;
    }
    const items = entered.map(([prize_id, value]) => ({ prize_id, qty: Number(value) }));
    setBusy(true); setError('');
    try {
      const result = await rpc('bulk_replenish_low_stock', { p_items: items, p_note: note || null });
      if (!result?.promoters_updated) {
        setError('No one is currently below the low-stock threshold. Refresh the dashboard and try again.');
        setBusy(false);
        return;
      }
      onClose(true);
    } catch (e) { setError(friendly(e)); setBusy(false); }
  }

  return (
    <Modal title="Bulk Replenish Low Stock" onClose={() => { if (!busy) onClose(false); }} wide>
      <div className="s-form">
        <p className="muted" style={{ margin: 0 }}>
          Enter each quantity once. It will be added to every promoter currently low on that prize. The server rechecks stock before issuing and records each movement in the inventory log.
        </p>
        <div className="bulk-stock-prizes">
          {targetPrizes.map((prize) => <Field key={prize.id} label={`${prize.short_name} — add to each low-stock promoter`}>
            <input type="number" min="1" step="1" value={quantities[prize.id] ?? ''}
              onChange={(event) => setQuantities({ ...quantities, [prize.id]: event.target.value })} />
          </Field>)}
        </div>
        <div className="bulk-stock-targets">
          <b>Low-stock promoters in scope: {targets.length}</b>
          {targets.map((person) => <div key={person.id}>
            {person.name}: {person.alerts.map((alert) => `${alert.prize} (${alert.on_hand} left)`).join(', ')}
          </div>)}
        </div>
        <Field label="Note / reference"><input value={note} onChange={(event) => setNote(event.target.value)} placeholder="e.g. Field stock top-up, 24 Oct" /></Field>
        {error && <div className="s-err">{error}</div>}
        <div className="s-actions">
          <button className="s-btn ghost" disabled={busy} onClick={() => onClose(false)}>Cancel</button>
          <button className="s-btn" disabled={busy || targetPrizes.length === 0 || recipientCount === 0 || Object.values(quantities).some((value) => Number(value) > 0 && !Number.isInteger(Number(value)))} onClick={save}>
            {busy ? 'Replenishing…' : `Replenish ${recipientCount} promoters`}
          </button>
        </div>
      </div>
    </Modal>
  );
}
