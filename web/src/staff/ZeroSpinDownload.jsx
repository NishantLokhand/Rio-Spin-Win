import React, { useState } from 'react';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { zeroSpinUsers, neverSpunUsers } from '../lib/zeroSpins.js';
import { reportPeriod } from '../lib/reportTotals.js';
import { Modal, DataTable } from './ui.jsx';

const columns = [
  { key: 'name', label: 'Name' }, { key: 'login', label: 'Login / Mobile' },
  { key: 'code', label: 'Promoter Code' }, { key: 'type', label: 'Type' },
  { key: 'city', label: 'City' },
  { key: 'status', label: 'Status' }, { key: 'spins', label: 'Spins' },
  { key: 'date_from', label: 'Date From' }, { key: 'date_to', label: 'Date To' },
];
const neverColumns = [
  { key: 'name', label: 'Name' }, { key: 'state', label: 'State' },
  { key: 'type', label: 'Type' }, { key: 'city', label: 'City' },
  { key: 'spins', label: 'Spins' }, { key: 'mobile', label: 'Mobile Number' },
];

export default function ZeroSpinDownload({ users, dates, snapshot }) {
  const [result, setResult] = useState(null);
  const [busy, setBusy] = useState(false);
  async function open(never = false) {
    const period = { date_from: dates.date_from, date_to: dates.date_to };
    setBusy(true);
    setResult({ period, never });
    try {
      if (never) {
        const checkedAt = new Date().toISOString();
        const [profiles, spins, people, states] = await Promise.all([
          selectAll('promoters', 'user_id,home_state_id'),
          selectAll('spins', 'promoter_id', (q) => q.lte('created_at', checkedAt).order('id')),
          selectAll('org_people', 'auth_user_id,designation,state_raw,market_raw,market_override,mobile', (q) => q.not('auth_user_id', 'is', null)),
          selectAll('states', 'id,name'),
        ]);
        setResult({ period, never, checkedAt, rows: neverSpunUsers(users, profiles, spins, people, states) });
        return;
      }
      const [profiles, activity, people] = await Promise.all([
        snapshot ? snapshot.promoters : selectAll('promoters', '*'),
        snapshot ? snapshot.activity : rpc('report_summary', { p_group: 'promoter', p_filters: period }),
        selectAll('org_people', 'auth_user_id,market_raw,market_override', (q) => q.not('auth_user_id', 'is', null)),
      ]);
      setResult({ period, rows: zeroSpinUsers(users, profiles, activity, period, people) });
    } catch (e) { setResult({ period, never, error: friendly(e) }); }
    finally { setBusy(false); }
  }
  return <>
    <span className="row-actions">
      <button className="s-btn ghost sm" disabled={busy} onClick={() => open()}>Download zero-spin users</button>
      <button className="s-btn ghost sm" disabled={busy} onClick={() => open(true)}>Never spun till date</button>
    </span>
    {result && <Modal wide title={result.never ? 'Users who have never spun' : 'Zero-spin users'} onClose={() => { if (!busy) setResult(null); }}>
      <p>{result.never ? <>Period: <strong>All-time spin history</strong>{result.checkedAt && <> · Checked {new Date(result.checkedAt).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' })} IST</>}</> : <>Period: <strong>{reportPeriod(result.period)}</strong></>}</p>
      <p className="muted">{result.never
        ? 'Users in your access with no recorded spins at any time, including disabled users. Selected report dates and other filters do not apply.'
        : 'All field users in your access, including disabled users. Uses these dates only; other report filters do not apply.'}</p>
      <p className="muted">City comes from the user’s organizational Market details. A blank means no Market is recorded.</p>
      {busy ? <p>Checking spin activity…</p> : result.error ? <p className="s-error">{result.error}</p> :
        <DataTable rows={result.rows} columns={result.never ? neverColumns : columns}
          empty={result.never ? 'All users have recorded at least one spin.' : 'No users with zero spins in this period.'}
          exportName={result.never ? `never_spun_users_${result.checkedAt.slice(0, 10)}` : `zero_spin_users_${result.period.date_from || 'beginning'}_${result.period.date_to || 'all'}`} />}
    </Modal>}
  </>;
}
