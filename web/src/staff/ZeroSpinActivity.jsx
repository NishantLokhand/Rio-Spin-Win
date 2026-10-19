import React, { useMemo, useState } from 'react';
import { friendly } from '../lib/api.js';
import { istToday } from '../lib/store.js';
import { shiftDate } from '../lib/reportDates.js';
import { isoWeek, zeroPeriod, zeroActivityRows } from '../lib/userActivity.js';
import { loadUserActivityData } from '../lib/userActivityData.js';
import { userReportColumns } from '../lib/userReportColumns.js';
import { Modal, DataTable } from './ui.jsx';

const columns = userReportColumns([
  { key: 'mobile', label: 'Mobile Number' }, { key: 'login', label: 'Login' },
  { key: 'account_status', label: 'Account Status' }, { key: 'account_date', label: 'Account Created' },
  { key: 'date_from', label: 'Date From' }, { key: 'date_to', label: 'Date To' }, { key: 'activity', label: 'Activity' },
]);

export default function ZeroSpinActivity({ dates, userType, userId }) {
  const [open, setOpen] = useState(false), [source, setSource] = useState(null), [error, setError] = useState('');
  const [busy, setBusy] = useState(false), [mode, setMode] = useState('day'), [selection, setSelection] = useState({});
  const [includeToday, setIncludeToday] = useState(false), [type, setType] = useState(''), [user, setUser] = useState('');
  async function load() {
    const today = istToday(), yesterday = shiftDate(today, -1);
    const anchor = dates.date_to && dates.date_to < today ? dates.date_to : yesterday;
    setSelection({ day: anchor, week: isoWeek(anchor), month: anchor.slice(0, 7), from: dates.date_from && dates.date_from <= anchor ? dates.date_from : anchor, to: anchor });
    setMode('day'); setType(userType || ''); setUser(userId || ''); setIncludeToday(false);
    setOpen(true); setBusy(true); setError(''); setSource(null);
    try { setSource({ ...await loadUserActivityData(), today }); }
    catch (e) { setError(friendly(e)); }
    finally { setBusy(false); }
  }
  const report = useMemo(() => {
    if (!source) return null;
    try {
      const period = zeroPeriod(mode, selection, source.today, includeToday);
      return { period, rows: zeroActivityRows(source, { ...period, today: source.today, userType: type, userId: user }) };
    } catch (e) { return { error: e.message }; }
  }, [source, mode, selection, includeToday, type, user]);
  const set = (key) => (e) => setSelection((s) => ({ ...s, [key]: e.target.value }));
  const allowed = source?.users.filter((u) => !type || source.people.some((p) => p.auth_user_id === u.id && p.designation === type)) || [];
  return <>
    <button className="s-btn ghost sm" disabled={busy} onClick={load}>Zero-spin activity</button>
    {open && <Modal wide title="Zero-spin activity — users and missing dates" onClose={() => setOpen(false)}>
      <p>One row per user per date without a recorded spin, including users who spun on other days and users who never spun. Dates before account creation are excluded. Disabled users are included and labelled.</p>
      <p className="muted">Choose a day, full calendar week (Monday–Sunday), month or custom range. Current weeks/months stop at yesterday unless you include today. Type and User start from the dashboard selection; other dashboard filters do not apply.</p>
      <div className="row-actions">
        <label>Report by <select aria-label="Zero-spin period" value={mode} onChange={(e) => setMode(e.target.value)}>
          <option value="day">Day-wise</option><option value="week">Week-wise</option><option value="month">Month-wise</option><option value="custom">Custom range</option>
        </select></label>
        {mode === 'day' && <label>Day <input aria-label="Zero-spin day" type="date" value={selection.day || ''} onChange={set('day')} /></label>}
        {mode === 'week' && <label>Week <input aria-label="Zero-spin week" type="week" value={selection.week || ''} onChange={set('week')} /></label>}
        {mode === 'month' && <label>Month <input aria-label="Zero-spin month" type="month" value={selection.month || ''} onChange={set('month')} /></label>}
        {mode === 'custom' && <>
          <label>From <input aria-label="Zero-spin from" type="date" value={selection.from || ''} onChange={set('from')} /></label>
          <label>To <input aria-label="Zero-spin to" type="date" value={selection.to || ''} onChange={set('to')} /></label>
        </>}
        <label><input type="checkbox" checked={includeToday} onChange={(e) => setIncludeToday(e.target.checked)} /> Include today (in progress)</label>
        <select aria-label="Zero-spin type" value={type} onChange={(e) => { setType(e.target.value); setUser(''); }}>
          <option value="">Type: All</option><option value="PROMOTER">Promoter</option><option value="TSE">TSE</option><option value="MER">MER</option>
        </select>
        <select aria-label="Zero-spin user" value={user} onChange={(e) => setUser(e.target.value)}><option value="">User: All</option>{allowed.map((u) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</select>
      </div>
      {error && <p className="s-err">{error}</p>}
      {busy ? <p>Loading daily activity…</p> : report?.error ? <p className="s-err">{report.error}</p> : report && <>
        <p>Period: <strong>{report.period.from} – {report.period.to}</strong> · {new Set(report.rows.map((r) => r.key)).size} users · {report.rows.length} zero-spin user-days</p>
        <p className="muted">Visits, units and costs are retained where recorded. No-activity locations come from the user profile; they are not visits. Activity % covers the chosen period, excluding today. Snack used percentages describe current stock. CSV and Excel keep each individual date.</p>
        <DataTable rows={report.rows} columns={columns} exportName={`zero_spin_activity_${mode}_${report.period.from}_${report.period.to}`}
          empty="No zero-spin user-days for this selection." />
      </>}
    </Modal>}
  </>;
}
