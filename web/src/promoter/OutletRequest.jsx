import React, { useState } from 'react';
import { rpc, friendly } from '../lib/api.js';

export default function OutletRequest({ ctx, onDone }) {
  const [f, setF] = useState({ name: '', area: '', city: ctx?.outletCity || '', ref: '', note: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });

  async function submit(e) {
    e.preventDefault();
    if (!f.name.trim() || !f.area.trim()) { setErr('Outlet name and area are required'); return; }
    setBusy(true); setErr('');
    try {
      await rpc('submit_outlet_request', { p_name: f.name, p_area: f.area, p_city: f.city, p_ref_code: f.ref || null,
        p_suggested_tse: null, p_note: f.note || null }, { retries: 2 });
      onDone(true);
    } catch (e2) { setErr(friendly(e2)); } finally { setBusy(false); }
  }

  return (
    <main className="picker">
      <div className="picker-top"><button className="back" onClick={() => onDone(false)}>‹</button><h2>OUTLET NOT LISTED</h2></div>
      <p className="note">Your supervisor/admin must approve the outlet before sales can be recorded there.</p>
      <form className="form" onSubmit={submit}>
        <label>Outlet name *<input value={f.name} onChange={set('name')} /></label>
        <label>Area / locality *<input value={f.area} onChange={set('area')} /></label>
        <label>City<input value={f.city} onChange={set('city')} /></label>
        <label>Outlet code / reference (optional)<input value={f.ref} onChange={set('ref')} /></label>
        <label>Note<input value={f.note} onChange={set('note')} /></label>
        {err && <div className="err">{err}</div>}
        <button className="btn-primary big" disabled={busy}>{busy ? 'Sending…' : 'SUBMIT FOR APPROVAL'}</button>
      </form>
    </main>
  );
}
