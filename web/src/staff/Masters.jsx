import React, { useMemo, useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { parseSheet, exportCSV, exportXLSX } from '../lib/exporter.js';
import { useAsync, Panel, Loading, DataTable, Modal, Field, Tabs, Badge } from './ui.jsx';

const TABS = [
  { key: 'outlets', label: 'Outlet Master' }, { key: 'tses', label: 'TSEs' }, { key: 'territories', label: 'Territories' },
  { key: 'states', label: 'States' }, { key: 'products', label: 'Products / SKUs' }, { key: 'prizes', label: 'Prizes' },
];

export default function Masters({ data, reloadData }) {
  const [tab, setTab] = useState('outlets');
  const m = data.masters;
  const all = useAsync(async () => {
    const [states, territories, tses, products, prizes] = await Promise.all([
      selectAll('states', '*', (q) => q.order('name')), selectAll('territories', '*', (q) => q.order('name')),
      selectAll('tses', '*', (q) => q.order('name')), selectAll('products', '*', (q) => q.order('sort_order')),
      selectAll('prizes', '*', (q) => q.order('sort_order')),
    ]);
    return { states, territories, tses, products, prizes };
  }, []);
  const refresh = () => { all.reload(); reloadData(); };
  if (!all.data) return <div className="s-page"><Loading state={all} /></div>;
  const A = all.data;
  const stateOpts = A.states.map((s) => [s.id, s.name]);
  const terrOpts = A.territories.map((t) => [t.id, `${t.name} (${A.states.find((s) => s.id === t.state_id)?.name || ''})`]);
  const tseOpts = A.tses.map((t) => [t.id, `${t.name} — ${t.code}`]);
  const status = { key: 'status', label: 'Status', type: 'select', options: [['active', 'Active'], ['inactive', 'Inactive']] };

  const CONFIG = {
    states: { table: 'states', rows: A.states, fields: [{ key: 'code', label: 'Code' }, { key: 'name', label: 'Name' }, status, { key: 'external_ref', label: 'External ref (SFA/ERP)' }],
      columns: [{ key: 'code', label: 'Code' }, { key: 'name', label: 'State' }] },
    territories: { table: 'territories', rows: A.territories.map((t) => ({ ...t, state: A.states.find((s) => s.id === t.state_id)?.name })),
      fields: [{ key: 'state_id', label: 'State', type: 'select', options: stateOpts }, { key: 'code', label: 'Code' }, { key: 'name', label: 'Name' }, status, { key: 'external_ref', label: 'External ref' }],
      columns: [{ key: 'code', label: 'Code' }, { key: 'name', label: 'Territory' }, { key: 'state', label: 'State' }] },
    tses: { table: 'tses', rows: A.tses.map((t) => ({ ...t, territory: A.territories.find((x) => x.id === t.territory_id)?.name })),
      fields: [{ key: 'territory_id', label: 'Territory', type: 'select', options: terrOpts }, { key: 'code', label: 'TSE code' }, { key: 'name', label: 'TSE name' },
        { key: 'mobile', label: 'Mobile' }, status, { key: 'external_ref', label: 'External ref (FieldAssist ID)' }],
      columns: [{ key: 'code', label: 'TSE Code' }, { key: 'name', label: 'TSE Name' }, { key: 'territory', label: 'Territory' }, { key: 'mobile', label: 'Mobile' }] },
    outlets: { table: 'outlets', rows: data.outletsFull.map((o) => {
        const t = A.tses.find((x) => x.id === o.tse_id); const tr = A.territories.find((x) => x.id === (o.territory_id || t?.territory_id));
        return { ...o, tse_code: t?.code, tse_name: t?.name, territory: tr?.name, state: A.states.find((s) => s.id === (o.state_id || tr?.state_id))?.name };
      }),
      fields: [{ key: 'tse_id', label: 'Mapped TSE', type: 'select', options: tseOpts }, { key: 'outlet_code', label: 'Outlet code' }, { key: 'name', label: 'Outlet name' },
        { key: 'area', label: 'Area' }, { key: 'beat', label: 'Beat' }, { key: 'city', label: 'City' }, { key: 'distributor', label: 'Distributor' }, status, { key: 'external_ref', label: 'External ref' }],
      columns: [{ key: 'state', label: 'State' }, { key: 'territory', label: 'Territory' }, { key: 'tse_code', label: 'TSE Code' }, { key: 'tse_name', label: 'TSE Name' },
        { key: 'outlet_code', label: 'Outlet Code' }, { key: 'name', label: 'Outlet Name' }, { key: 'area', label: 'Area' }, { key: 'beat', label: 'Beat' }, { key: 'city', label: 'City' },
        { key: 'distributor', label: 'Distributor' }, { key: 'source', label: 'Source' }] },
    products: { table: 'products', rows: A.products, boolStatus: true,
      fields: [{ key: 'sku_code', label: 'SKU code' }, { key: 'name', label: 'Product name' }, { key: 'pack', label: 'Pack' }, { key: 'size_ml', label: 'Size (ml)', type: 'number' },
        { key: 'mrp', label: 'MRP (₹)', type: 'number' }, { key: 'sort_order', label: 'Sort order', type: 'number' }, { key: 'is_active', label: 'Active', type: 'checkbox' }, { key: 'external_ref', label: 'External ref (ERP SKU)' }],
      columns: [{ key: 'sku_code', label: 'SKU' }, { key: 'name', label: 'Product' }, { key: 'pack', label: 'Pack' }, { key: 'size_ml', label: 'ml', align: 'r' }] },
    prizes: { table: 'prizes', rows: A.prizes, boolStatus: true, image: true,
      fields: [{ key: 'code', label: 'Code' }, { key: 'name', label: 'Prize name' }, { key: 'short_name', label: 'Short name' },
        { key: 'tier', label: 'Celebration tier', type: 'select', options: [['standard', 'Standard'], ['mid', 'Mid (Rio Dare)'], ['high', 'High (Shades)'], ['jackpot', 'Jackpot']] },
        { key: 'default_cost', label: 'Default cost (₹)', type: 'number' }, { key: 'low_stock_threshold', label: 'Low-stock threshold', type: 'number' },
        { key: 'wheel_label', label: 'Wheel label (display follows prize code)', hint: 'The customer wheel uses only the five campaign prizes: ₹5 Snack, ₹10 Snack, Rio Dare Card Game, Rio Sunglasses, and Rio Mini Bluetooth Speaker.' },
        { key: 'win_title', label: 'Winner headline' }, { key: 'win_subtitle', label: 'Winner sub-headline' },
        { key: 'sort_order', label: 'Sort order', type: 'number' }, { key: 'is_active', label: 'Active', type: 'checkbox' }],
      columns: [{ key: 'image_url', label: '', noExport: true, render: (r) => (r.image_url ? <img className="thumb" src={r.image_url} alt="" /> : null) },
        { key: 'code', label: 'Code' }, { key: 'name', label: 'Prize' }, { key: 'tier', label: 'Tier' }, { key: 'default_cost', label: 'Cost', align: 'r' },
        { key: 'low_stock_threshold', label: 'Low-stock at', align: 'r' }, { key: 'wheel_label', label: 'Wheel segments' }] },
  };

  return (
    <div className="s-page">
      <Tabs tabs={TABS} value={tab} onChange={setTab} />
      {tab === 'outlets' && <OutletUpload onDone={refresh} />}
      <MasterTable key={tab} cfg={CONFIG[tab]} title={TABS.find((t) => t.key === tab).label} onSaved={refresh} />
    </div>
  );
}

function MasterTable({ cfg, title, onSaved }) {
  const [edit, setEdit] = useState(null);
  const [q, setQ] = useState('');
  const rows = useMemo(() => {
    const s = q.toLowerCase();
    return s ? cfg.rows.filter((r) => Object.values(r).some((v) => String(v ?? '').toLowerCase().includes(s))) : cfg.rows;
  }, [q, cfg.rows]);
  const active = (r) => (cfg.boolStatus ? r.is_active : r.status === 'active');
  return (
    <Panel title={title} actions={<>
      <input className="s-search" placeholder="Search…" value={q} onChange={(e) => setQ(e.target.value)} />
      <button className="s-btn sm" onClick={() => setEdit(cfg.boolStatus ? { is_active: true } : { status: 'active' })}>+ Add</button></>}>
      <DataTable rows={rows} exportName={cfg.table} maxHeight="65vh" columns={[
        ...cfg.columns,
        { key: 'st', label: 'Status', noExport: true, render: (r) => <Badge tone={active(r) ? 'green' : 'grey'}>{active(r) ? 'Active' : 'Inactive'}</Badge> },
        { key: 'e', label: '', noExport: true, render: (r) => <button className="s-btn ghost sm" onClick={() => setEdit(r)}>Edit</button> },
      ]} />
      {edit && <EditModal cfg={cfg} row={edit} onClose={(c) => { setEdit(null); if (c) onSaved(); }} />}
    </Panel>
  );
}

function EditModal({ cfg, row, onClose }) {
  const [f, setF] = useState(row);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [file, setFile] = useState(null);

  async function save() {
    setBusy(true); setErr('');
    try {
      const payload = Object.fromEntries(cfg.fields.map((fl) => {
        let v = f[fl.key];
        if (fl.type === 'number') v = v === '' || v == null ? null : Number(v);
        if (fl.type === 'checkbox') v = !!v;
        if (typeof v === 'string') v = v.trim() === '' ? null : v.trim();
        return [fl.key, v];
      }));
      if (cfg.image && file) {
        const path = `${payload.code || 'prize'}-${Date.now()}.${file.name.split('.').pop()}`;
        const up = await supabase.storage.from('prize-images').upload(path, file, { upsert: true });
        if (up.error) throw up.error;
        payload.image_url = supabase.storage.from('prize-images').getPublicUrl(path).data.publicUrl;
      }
      const res = row.id ? await supabase.from(cfg.table).update(payload).eq('id', row.id) : await supabase.from(cfg.table).insert(payload);
      if (res.error) throw res.error;
      onClose(true);
    } catch (e) { setErr(friendly(e)); setBusy(false); }
  }

  return (
    <Modal title={row.id ? 'Edit' : 'Add'} onClose={() => onClose(false)}>
      <div className="s-form">
        {cfg.fields.map((fl) => (
          <Field key={fl.key} label={fl.label} hint={fl.hint}>
            {fl.type === 'select' ? (
              <select value={f[fl.key] ?? ''} onChange={(e) => setF({ ...f, [fl.key]: e.target.value })}>
                <option value="">— select —</option>{fl.options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            ) : fl.type === 'checkbox' ? (
              <input type="checkbox" checked={!!f[fl.key]} onChange={(e) => setF({ ...f, [fl.key]: e.target.checked })} />
            ) : <input type={fl.type || 'text'} value={f[fl.key] ?? ''} onChange={(e) => setF({ ...f, [fl.key]: e.target.value })} />}
          </Field>
        ))}
        {cfg.image && (
          <Field label="Prize image">
            {f.image_url && <img className="thumb lg" src={f.image_url} alt="" />}
            <input type="file" accept="image/*" onChange={(e) => setFile(e.target.files[0])} />
          </Field>
        )}
        <div className="s-note">Records are never deleted — set them Inactive. Historical transactions keep the names/mapping they were recorded with.</div>
        {err && <div className="s-err">{err}</div>}
        <div className="s-actions"><button className="s-btn ghost" onClick={() => onClose(false)}>Cancel</button>
          <button className="s-btn" disabled={busy} onClick={save}>{busy ? 'Saving…' : 'Save'}</button></div>
      </div>
    </Modal>
  );
}

const TEMPLATE_COLS = ['state', 'territory', 'tse_code', 'tse_name', 'outlet_code', 'outlet_name', 'area', 'beat', 'city', 'distributor', 'status'];

function OutletUpload({ onDone }) {
  const [res, setRes] = useState(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const template = [{ state: 'Uttar Pradesh', territory: 'Lucknow Central', tse_code: 'TSE-UP-001', tse_name: 'Rahul Sharma', outlet_code: 'LKO-0001',
    outlet_name: 'Modern Wines', area: 'Hazratganj', beat: 'Hazratganj Beat 1', city: 'Lucknow', distributor: 'Awadh Beverages', status: 'Active' }];
  const cols = TEMPLATE_COLS.map((k) => ({ key: k, label: k }));

  async function upload(e) {
    const file = e.target.files[0]; e.target.value = '';
    if (!file) return;
    setBusy(true); setErr(''); setRes(null);
    try {
      const rows = (await parseSheet(file)).map((r) => ({ ...r, outlet_name: r.outlet_name || r.name, status: r.status || r.outlet_status }));
      if (!rows.length) throw new Error('No rows found in file');
      let total = { rows: 0, inserted: 0, updated: 0, errors: [] };
      for (let i = 0; i < rows.length; i += 500) {         // chunks keep each call small
        const r = await rpc('import_outlets', { p_rows: rows.slice(i, i + 500) });
        total = { rows: total.rows + r.rows, inserted: total.inserted + r.inserted, updated: total.updated + r.updated,
          errors: [...total.errors, ...r.errors.map((x) => ({ ...x, row: x.row + i + 1 }))] };
      }
      setRes(total); onDone();
    } catch (e2) { setErr(friendly(e2)); } finally { setBusy(false); }
  }

  return (
    <Panel title="Upload Outlet Master (Excel / CSV)">
      <div className="upload-row">
        <label className="s-btn">{busy ? 'Uploading…' : 'Choose .xlsx / .csv file'}<input type="file" accept=".xlsx,.xls,.csv" hidden onChange={upload} disabled={busy} /></label>
        <button className="s-btn ghost sm" onClick={() => exportXLSX(template, cols, 'outlet_master_template')}>Template (Excel)</button>
        <button className="s-btn ghost sm" onClick={() => exportCSV(template, cols, 'outlet_master_template')}>Template (CSV)</button>
        <small className="muted">Columns: {TEMPLATE_COLS.join(', ')}. Existing outlet codes are updated; new States / Territories / TSEs are created automatically.</small>
      </div>
      {err && <div className="s-err">{err}</div>}
      {res && <div className={res.errors.length ? 's-note' : 's-ok'}>
        {res.rows} rows · {res.inserted} added · {res.updated} updated · {res.errors.length} errors
        {res.errors.slice(0, 20).map((x, i) => <div key={i}>Row {x.row}: {x.error}</div>)}
      </div>}
    </Panel>
  );
}
