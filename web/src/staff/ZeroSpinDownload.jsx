import React, { useState } from 'react';
import { friendly } from '../lib/api.js';
import { loadUserActivityData } from '../lib/userActivityData.js';
import { zeroCohortRows } from '../lib/userActivity.js';
import { userReportColumns } from '../lib/userReportColumns.js';
import { istToday } from '../lib/store.js';
import { reportPeriod } from '../lib/reportTotals.js';
import ZeroSpinActivity from './ZeroSpinActivity.jsx';
import { Modal, DataTable } from './ui.jsx';

const columns = userReportColumns([
  { key: 'login', label: 'Login' }, { key: 'mobile', label: 'Mobile Number' },
  { key: 'account_status', label: 'Account Status' }, { key: 'account_date', label: 'Account Created' },
  { key: 'date_from', label: 'Date From' }, { key: 'date_to', label: 'Date To' },
  { key: 'activity', label: 'Activity' },
]);

export default function ZeroSpinDownload({ dates, userType = '', userId = '' }) {
  const [result, setResult] = useState(null);
  const [busy, setBusy] = useState(false);
  async function open(never = false) {
    const today = istToday();
    const period = never ? { date_to: today } : { date_from: dates.date_from, date_to: dates.date_to && dates.date_to < today ? dates.date_to : today };
    setBusy(true); setResult({ period, never });
    try {
      const source = await loadUserActivityData();
      const rows = zeroCohortRows(source, { from: period.date_from, to: period.date_to, today, never });
      setResult({ period, never, rows });
    } catch (e) { setResult({ period, never, error: friendly(e) }); }
    finally { setBusy(false); }
  }
  return <>
    <span className="row-actions">
      <button className="s-btn ghost sm" disabled={busy} onClick={() => open()}>Download zero-spin users</button>
      <button className="s-btn ghost sm" disabled={busy} onClick={() => open(true)}>Never spun till date</button>
      <ZeroSpinActivity dates={dates} userType={userType} userId={userId} />
    </span>
    {result && <Modal wide title={result.never ? 'Users who have never spun' : 'Zero-spin users'} onClose={() => { if (!busy) setResult(null); }}>
      <p>Period: <strong>{result.never ? 'Account creation through today — all-time spin check' : reportPeriod(result.period)}</strong></p>
      <p className="muted">{result.never ? 'Users with no recorded spins at any time.' : 'Users with zero spins throughout the selected period.'} Includes disabled users in your access. Other dashboard filters do not apply. Date is the summary end date; Date From/To show the period. Use Zero-spin activity for individual missing dates.</p>
      <p className="muted">Type is Promoter/TSE/MER. Recorded activity supplies outlet geography; otherwise State/City/Area come from the linked profile. Sales and visits are preserved even with zero spins. Activity % excludes today. Snack used % is current stock usage, not historical usage.</p>
      {busy ? <p>Checking spin activity…</p> : result.error ? <p className="s-error">{result.error}</p> :
        <DataTable rows={result.rows} columns={columns}
          empty={result.never ? 'All users have recorded at least one spin.' : 'No users with zero spins throughout this period.'}
          exportName={`${result.never ? 'never_spun' : 'zero_spin'}_users_${result.period.date_from || 'beginning'}_${result.period.date_to}`} />}
    </Modal>}
  </>;
}
