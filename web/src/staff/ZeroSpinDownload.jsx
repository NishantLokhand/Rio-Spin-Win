import React, { useState } from 'react';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { zeroSpinUsers } from '../lib/zeroSpins.js';
import { reportPeriod } from '../lib/reportTotals.js';
import { Modal, DataTable } from './ui.jsx';

const columns = [
  { key: 'name', label: 'Name' }, { key: 'login', label: 'Login / Mobile' },
  { key: 'code', label: 'Promoter Code' }, { key: 'type', label: 'Type' },
  { key: 'city', label: 'City' },
  { key: 'status', label: 'Status' }, { key: 'spins', label: 'Spins' },
  { key: 'date_from', label: 'Date From' }, { key: 'date_to', label: 'Date To' },
];

export default function ZeroSpinDownload({ users, dates, snapshot }) {
  const [result, setResult] = useState(null);
  const [busy, setBusy] = useState(false);
  async function open() {
    const period = { date_from: dates.date_from, date_to: dates.date_to };
    setBusy(true);
    setResult({ period });
    try {
      const [profiles, activity, people] = await Promise.all([
        snapshot ? snapshot.promoters : selectAll('promoters', '*'),
        snapshot ? snapshot.activity : rpc('report_summary', { p_group: 'promoter', p_filters: period }),
        selectAll('org_people', 'auth_user_id,market_raw,market_override', (q) => q.not('auth_user_id', 'is', null)),
      ]);
      setResult({ period, rows: zeroSpinUsers(users, profiles, activity, period, people) });
    } catch (e) { setResult({ period, error: friendly(e) }); }
    finally { setBusy(false); }
  }
  return <>
    <button className="s-btn ghost sm" disabled={busy} onClick={open}>Download zero-spin users</button>
    {result && <Modal wide title="Zero-spin users" onClose={() => { if (!busy) setResult(null); }}>
      <p>Period: <strong>{reportPeriod(result.period)}</strong></p>
      <p className="muted">All field users in your access, including disabled users. Uses these dates only; other report filters do not apply.</p>
      <p className="muted">City comes from the user’s organizational Market details. A blank means no Market is recorded.</p>
      {busy ? <p>Checking spin activity…</p> : result.error ? <p className="s-error">{result.error}</p> :
        <DataTable rows={result.rows} columns={columns} empty="No users with zero spins in this period."
          exportName={`zero_spin_users_${result.period.date_from || 'beginning'}_${result.period.date_to || 'all'}`} />}
    </Modal>}
  </>;
}
