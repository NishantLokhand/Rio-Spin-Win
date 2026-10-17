import React, { useState } from 'react';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { zeroSpinUsers } from '../lib/zeroSpins.js';
import { reportPeriod } from '../lib/reportTotals.js';
import { Modal, DataTable } from './ui.jsx';

const columns = [
  { key: 'name', label: 'Name' }, { key: 'login', label: 'Login / Mobile' },
  { key: 'code', label: 'Promoter Code' }, { key: 'type', label: 'Type' },
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
      const [profiles, activity] = snapshot ? [snapshot.promoters, snapshot.activity] : await Promise.all([
        selectAll('promoters', '*'),
        rpc('report_summary', { p_group: 'promoter', p_filters: period }),
      ]);
      setResult({ period, rows: zeroSpinUsers(users, profiles, activity, period) });
    } catch (e) { setResult({ period, error: friendly(e) }); }
    finally { setBusy(false); }
  }
  return <>
    <button className="s-btn ghost sm" disabled={busy} onClick={open}>Download zero-spin users</button>
    {result && <Modal wide title="Zero-spin users" onClose={() => { if (!busy) setResult(null); }}>
      <p>Period: <strong>{reportPeriod(result.period)}</strong></p>
      <p className="muted">All field users in your access, including disabled users. Uses these dates only; other report filters do not apply.</p>
      {busy ? <p>Checking spin activity…</p> : result.error ? <p className="s-error">{result.error}</p> :
        <DataTable rows={result.rows} columns={columns} empty="No users with zero spins in this period."
          exportName={`zero_spin_users_${result.period.date_from || 'beginning'}_${result.period.date_to || 'all'}`} />}
    </Modal>}
  </>;
}
