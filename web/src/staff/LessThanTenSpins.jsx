import React, { useState } from 'react';
import { rpc, friendly } from '../lib/api.js';
import { istToday } from '../lib/store.js';
import { shiftDate } from '../lib/reportDates.js';
import { userReportColumns } from '../lib/userReportColumns.js';
import { Modal, DataTable, Kpi } from './ui.jsx';

const columns = userReportColumns([
  { key: 'mobile', label: 'Mobile Number' }, { key: 'login', label: 'Login' },
  { key: 'account_status', label: 'Account Status' }, { key: 'account_date', label: 'Account Created' },
]);
export default function LessThanTenSpins({ dates }) {
  const [open, setOpen] = useState(false), [date, setDate] = useState('');
  const [result, setResult] = useState(null), [error, setError] = useState(''), [busy, setBusy] = useState(false);
  const [state, setState] = useState(''), [type, setType] = useState('');
  async function load(day) {
    setOpen(true); setBusy(true); setError(''); setResult(null); setDate(day);
    try { setResult(await rpc('report_less_than_ten_spins', { p_date: day })); }
    catch (e) { setError(friendly(e)); }
    finally { setBusy(false); }
  }
  const rows = (result?.rows || []).filter(r => (!state || r.state === state) && (!type || r.user_type === type));
  return <>
    <button className="s-btn ghost sm" disabled={busy} onClick={() => {
      const today = istToday(); setState(''); setType('');
      load(dates.date_to && dates.date_to <= today ? dates.date_to : shiftDate(today, -1));
    }}>Less than 10 spins users</button>
    {open && <Modal wide title="Less than 10 spins users" onClose={() => setOpen(false)}>
      <p>Active field users with <strong>0–9 recorded spins on the selected India business date</strong>. Demo/test, deleted and excluded accounts are omitted.</p>
      <div className="row-actions">
        <label>Date <input aria-label="Less than 10 spins date" type="date" max={istToday()} value={date} onChange={e => setDate(e.target.value)} /></label>
        <button className="s-btn sm" disabled={busy || !date || date > istToday()} onClick={() => load(date)}>Load date</button>
        <select aria-label="Less than 10 spins state" value={state} onChange={e => setState(e.target.value)}>
          <option value="">State: All</option>{(result?.states || []).map(s => <option key={s.label} value={s.label}>{s.label}</option>)}
        </select>
        <select aria-label="Less than 10 spins type" value={type} onChange={e => setType(e.target.value)}>
          <option value="">Type: All</option><option>Promoter</option><option>TSE</option><option>MER</option><option>Unknown</option>
        </select>
      </div>
      {error && <p className="s-err">{error}</p>}
      {busy ? <p>Loading daily spin activity…</p> : result && <>
        <p>Report date: <strong>{result.date}</strong>{result.in_progress ? ' · Today is still in progress' : ' · Complete day'} · All campaign spins are counted; other dashboard transaction filters do not apply.</p>
        <div className="kpis">
          <Kpi label="Users below 10" value={result.summary.below_target} />
          <Kpi label="Zero spins" value={result.summary.zero_users} />
          <Kpi label="1–9 spins" value={result.summary.low_active_users} />
          <Kpi label="Users with 10+ spins" value={result.summary.target_reached} />
          <Kpi label="Eligible active users" value={result.summary.total_users} />
        </div>
        <p className="muted">State, City and Area describe the linked user profile. Outlets show recorded visits, without substituting a nearby outlet. Stock usage percentages describe current balances. First/last spin times are IST; activity span includes gaps.</p>
        <DataTable rows={rows} columns={columns} exportName={`less_than_10_spins_users_${result.date}`}
          empty="No users with 0–9 spins for this selection." />
      </>}
    </Modal>}
  </>;
}
