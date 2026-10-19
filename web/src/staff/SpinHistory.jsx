import React, { useMemo, useState } from 'react';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { istToday } from '../lib/store.js';
import { historyRange, spinHistory } from '../lib/spinHistory.js';
import { exportWorkbook } from '../lib/exporter.js';
import { Modal, DataTable, Tabs } from './ui.jsx';

const identity = [
  { key: 'label', label: 'User' }, { key: 'user_type', label: 'Type' },
  { key: 'state', label: 'State' }, { key: 'city', label: 'City' }, { key: 'area', label: 'Area' },
];
const summaryColumns = [...identity,
  { key: 'first_spin', label: 'First-ever Spin' }, { key: 'last_spin', label: 'Latest Spin (All Time)' },
  { key: 'last_spin_as_of', label: 'Last Spin As Of End Date' },
  { key: 'date_from', label: 'Period From' }, { key: 'date_to', label: 'Period To' },
  { key: 'total_spins', label: 'Period Spins' }, { key: 'active_days', label: 'Completed Days With Spins' },
  { key: 'no_spin_days', label: 'Completed Days Without Spins' },
  { key: 'completed_days', label: 'Completed Days' }, { key: 'consistency_pct', label: 'Consistency %' },
  { key: 'current_streak', label: 'Active Streak (Completed Days)' }, { key: 'longest_streak', label: 'Longest Streak In Period' },
  { key: 'days_since_last', label: 'Days Since Last Spin At End Date' },
];
const dailyColumns = [{ key: 'date', label: 'Date' }, ...identity,
  { key: 'outlets', label: 'Outlets Visited' }, { key: 'active_outlets', label: 'Outlets Covered' },
  { key: 'spins', label: 'Spins' }, { key: 'units', label: 'Units Sold' },
  { key: 'giveaway_cost', label: 'Giveaway Cost' }, { key: 'avg_cost', label: 'Average Cost' },
  { key: 'status', label: 'Activity' },
];

export default function SpinHistory({ filters, userType }) {
  const [open, setOpen] = useState(false), [busy, setBusy] = useState(false);
  const [error, setError] = useState(''), [source, setSource] = useState(null);
  const [range, setRange] = useState({ from: '', to: istToday() });
  const [tab, setTab] = useState('summary'), [user, setUser] = useState('');
  async function load(mode) {
    const today = istToday();
    const end = filters.date_to && filters.date_to < today ? filters.date_to : today;
    setRange(historyRange(mode, end)); setTab('summary'); setUser('');
    setOpen(true); setBusy(true); setError(''); setSource(null);
    try {
      const [rows, people] = await Promise.all([
        rpc('report_user_daily', { p_filters: {}, p_user_type: userType || null }),
        selectAll('org_people', 'auth_user_id,state_raw,market_raw,market_override,area_raw,area_override', (q) => q.not('auth_user_id', 'is', null)),
      ]);
      setSource({ rows: filters.promoter_id ? rows.filter((r) => r.key === filters.promoter_id) : rows, people, today });
    } catch (e) { setError(friendly(e)); }
    finally { setBusy(false); }
  }
  const report = useMemo(() => {
    if (!source) return null;
    try { return spinHistory(source.rows.filter((r) => !user || r.key === user), { ...range, today: source.today }, source.people); }
    catch (e) { return { error: e.message }; }
  }, [source, range, user]);
  const users = useMemo(() => [...new Map((source?.rows || []).map((r) => [r.key, r.label])).entries()]
    .sort((a, b) => a[1].localeCompare(b[1])), [source]);
  const name = `spin_history_${range.from || 'beginning'}_${range.to}`;
  async function download() {
    setError('');
    try { await exportWorkbook([
      { name: 'Summary', rows: report.summary, columns: summaryColumns },
      { name: 'Daily Detail', rows: report.daily, columns: dailyColumns },
    ], name); } catch (e) { setError(friendly(e)); }
  }
  return <>
    <span className="row-actions">{[['all', 'Spin history till date'], ['weekly', 'Weekly'], ['monthly', 'Monthly']].map(([mode, label]) =>
      <button key={mode} className="s-btn ghost sm" disabled={busy} onClick={() => load(mode)}>{label}</button>)}</span>
    {open && <Modal wide title="User spin history" onClose={() => setOpen(false)}>
      <p>Weekly starts Monday; Monthly starts on the first. Both initially end at the report’s selected end date, capped at today.</p>
      <p className="muted">Uses the selected Type and User across all campaigns and outlets. Other report filters do not apply. First/latest spin dates use all-time history. Daily detail starts at each user’s first spin; no-spin days are calendar days, not confirmed absences. Today is excluded from completed-day counts, consistency and streaks.</p>
      <div className="row-actions">
        <label>From <input aria-label="History From" type="date" value={range.from} max={range.to} onChange={(e) => setRange({ ...range, from: e.target.value })} /></label>
        <label>To <input aria-label="History To" type="date" value={range.to} max={istToday()} onChange={(e) => setRange({ ...range, to: e.target.value })} /></label>
        <select aria-label="History User" value={user} onChange={(e) => setUser(e.target.value)}><option value="">User: All</option>{users.map(([id, label]) => <option key={id} value={id}>{label}</option>)}</select>
      </div>
      {error && <p className="s-err">{error}</p>}
      {busy ? <p>Loading daily history…</p> : report?.error ? <p className="s-err">{report.error}</p> : report && <>
        <button className="s-btn sm" disabled={!report.summary.length} onClick={download}>Excel — Summary + Daily Detail</button>
        <Tabs value={tab} onChange={setTab} tabs={[{ key: 'summary', label: 'User Summary' }, { key: 'daily', label: 'Daily Detail' }]} />
        <DataTable rows={report[tab]} columns={tab === 'summary' ? summaryColumns : dailyColumns}
          exportName={`${name}_${tab}`} empty="No users with recorded spins for this selection." />
      </>}
    </Modal>}
  </>;
}
