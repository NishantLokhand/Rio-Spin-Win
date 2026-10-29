import React, { useState } from 'react';
import { rpc, friendly } from '../lib/api.js';
import { exportWorkbook } from '../lib/exporter.js';
import { DataTable, Modal } from './ui.jsx';

const columns = [
  { key: 'full_name', label: 'User' }, { key: 'mode', label: 'Version 7 Rule' },
  { key: 'state', label: 'State' }, { key: 'city', label: 'City' }, { key: 'area', label: 'Area' },
  { key: 'spins', label: 'Spins', align: 'r' }, { key: 'giveaway_cost', label: 'Giveaway Cost', align: 'r' },
  { key: 'snack5', label: '₹5 Stock' }, { key: 'snack10', label: '₹10 Stock' }, { key: 'shades', label: 'Rio Shades Stock' },
  { key: 'snack5_used', label: '₹5 Prizes Won' }, { key: 'snack10_used', label: '₹10 Prizes Won' }, { key: 'shades_used', label: 'Shades Won' },
  { key: 'expires_on', label: 'Rule Expires' },
];
const label = (mode) => mode === 'shades' ? '90% ₹10 / 6% ₹5 / 4% shades' : mode === 'no_snack5' ? '96% ₹10 / 4% shades' : '95% ₹10 / 5% ₹5';

export default function V7ExpiryReport() {
  const [open, setOpen] = useState(false), [rows, setRows] = useState([]), [error, setError] = useState(''), [busy, setBusy] = useState(false);
  async function load() {
    setOpen(true); setBusy(true); setError('');
    try {
      const data = await rpc('report_v7_expiry_users', {});
      setRows((data || []).map((r) => ({ ...r, mode: r.effective_rule || label(r.mode), snack5: r.stock?.SNACK5 ?? 0, snack10: r.stock?.SNACK10 ?? 0, shades: r.stock?.SHADES ?? 0 })));
    } catch (e) { setError(friendly(e)); } finally { setBusy(false); }
  }
  async function download() { await exportWorkbook([{ name: 'Version 7 Users', rows, columns }], 'version_7_expiry_users'); }
  return <>
    <button className="s-btn ghost sm" onClick={load}>Version 7 expiry users</button>
    {open && <Modal wide title="Version 7 expiry-stock users" onClose={() => setOpen(false)}>
      <p className="muted">Temporary allocation through 4 November 2026. Stock values are current remaining stock.</p>
      {error && <p className="s-err">{error}</p>}
      {busy ? <p>Loading…</p> : <><button className="s-btn sm" disabled={!rows.length} onClick={download}>Excel</button><DataTable rows={rows} columns={columns} exportName="version_7_expiry_users" /></>}
    </Modal>}
  </>;
}
