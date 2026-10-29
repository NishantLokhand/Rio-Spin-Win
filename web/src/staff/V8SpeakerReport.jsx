import React, { useState } from 'react';
import { rpc, friendly } from '../lib/api.js';
import { istToday } from '../lib/store.js';
import { DataTable, Modal } from './ui.jsx';

const columns = [
  { key: 'date', label: 'Date' }, { key: 'full_name', label: 'User' },
  { key: 'state', label: 'State' }, { key: 'city', label: 'City' }, { key: 'area', label: 'Area' },
  { key: 'reported_speakers', label: 'Reported Initial Speakers', align: 'r' },
  { key: 'speakers_remaining', label: 'Speakers Remaining', align: 'r' },
  { key: 'spins_today', label: 'Spins on Date', align: 'r' }, { key: 'status', label: 'Daily Speaker Status' },
  { key: 'spin_code', label: 'Speaker Spin' }, { key: 'awarded_at', label: 'Awarded At' },
  { key: 'redemption_status', label: 'Handover Status' },
];
export default function V8SpeakerReport() {
  const [open, setOpen] = useState(false), [date, setDate] = useState(istToday());
  const [rows, setRows] = useState([]), [error, setError] = useState(''), [busy, setBusy] = useState(false);
  async function load(value = date) {
    setOpen(true); setBusy(true); setError(''); setRows([]);
    try { setRows(await rpc('report_v8_speaker_users', { p_date: value })); }
    catch (err) { setError(friendly(err)); }
    finally { setBusy(false); }
  }
  return <>
    <button className="s-btn ghost sm" onClick={() => load()}>Version 8 speakers</button>
    {open && <Modal wide title="Version 8 daily speakers" onClose={() => setOpen(false)}>
      <p className="muted">One speaker per selected user on their third daily spin. Remaining stock is current available stock; activity uses the date below in India time.</p>
      <div className="row-actions"><input aria-label="Speaker report date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        <button className="s-btn sm" disabled={busy || !date} onClick={() => load()}>Load date</button></div>
      {error && <div className="s-err">{error}</div>}
      {busy ? <p>Loading…</p> : <DataTable rows={rows} columns={columns} exportName={`version_8_speakers_${date}`} />}
    </Modal>}
  </>;
}
