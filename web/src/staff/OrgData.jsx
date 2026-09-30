import React, { useMemo, useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { Panel, DataTable, Field, Badge, Tabs } from './ui.jsx';

const norm = (v) => String(v ?? '').trim().replace(/\s+/g, ' ');
const keyPart = (v) => norm(v).toUpperCase().replace(/[^A-Z0-9]+/g, '-').replace(/^-|-$/g, '');
const role = (v) => ({ PROMOTER: 'PROMOTER', PROMO: 'PROMOTER', TSE: 'TSE', MER: 'MER', ASM: 'ASM' }[norm(v).toUpperCase()] || '');
async function readSheet(file) {
  const XLSX = await import('xlsx');
  const book = XLSX.read(await file.arrayBuffer(), { type: 'array' });
  return XLSX.utils.sheet_to_json(book.Sheets[book.SheetNames[0]], { header: 1, defval: '' });
}
function parseUP(rows) {
  return rows.slice(1).filter((r) => norm(r[2]) && role(r[3])).map((r) => ({
    designation: role(r[3]), employee_name: norm(r[2]), state_raw: 'UTTAR PRADESH', market_raw: norm(r[0]), area_raw: norm(r[1]),
    beat_values: r.slice(4).map(norm).filter(Boolean), source_system: 'UP_TSE_MER_PROMO_AREAS', source_ids: { source_row: rows.indexOf(r) + 1 },
    source_key: `UP:${role(r[3])}:${keyPart(r[2])}:${keyPart(r[0])}:${keyPart(r[1])}`,
  }));
}
function parseMH(rows) {
  return rows.slice(1).filter((r) => norm(r[6]) && role(r[7])).map((r) => ({
    designation: role(r[7]), employee_name: norm(r[6]), mobile: norm(r[8]), fas_id: norm(r[1]), qa_employee_id: norm(r[2]),
    state_raw: norm(r[4]), market_raw: norm(r[5]), zone_raw: norm(r[3]), area_raw: norm(r[9]), beat_values: r.slice(10).map(norm).filter(Boolean),
    source_system: 'MH_TSE_MER_PROMO_AREAS', source_ids: { sr_no: norm(r[0]) },
    source_key: `MH:${norm(r[1]) || norm(r[2]) || norm(r[8]) || `${role(r[7])}:${keyPart(r[6])}:${keyPart(r[4])}:${keyPart(r[5])}`}`,
  }));
}
function parseInventory(rows) {
  return rows.slice(1).map((r, index) => ({ r, source_row: index + 2 })).filter(({ r }) => norm(r[6]) && role(r[7])).map(({ r, source_row }) => ({
    source_row, employee_name: norm(r[6]), designation: role(r[7]), fas_id: norm(r[1]), qa_employee_id: norm(r[2]), zone_raw: norm(r[3]),
    state_raw: norm(r[4]), market_raw: norm(r[5]), mobile: norm(r[8]), area_raw: norm(r[9]), snack5: Number(r[10]) || 0, snack10: Number(r[11]) || 0,
  }));
}

export default function OrgData({ data, reloadData }) {
  const [tab, setTab] = useState('people');
  const [people, setPeople] = useState(null);
  const [stock, setStock] = useState(null);
  const [stockAdjustments, setStockAdjustments] = useState([]);
  const [promoterStock, setPromoterStock] = useState([]);
  const [assignments, setAssignments] = useState(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const [files, setFiles] = useState({ up: null, mh: null, inventory: null });
  const [runKey, setRunKey] = useState('source-files-2026-09-30-v1');
  const [filters, setFilters] = useState({ designation: 'all', state: 'all', market: 'all', area: 'all', beat: 'all', tse: 'all', mer: 'all', assignment: 'all', inventory: 'all', active: 'all', q: '' });
  const [newPerson, setNewPerson] = useState({ designation: 'PROMOTER', employee_name: '', mobile: '', state_raw: '', market_raw: '', area_raw: '', beat: '' });

  async function refresh() {
    try {
      const [p, i, a, adj, pi] = await Promise.all([
        selectAll('org_people', '*', (q) => q.order('designation').order('employee_name')),
        selectAll('org_inventory', '*', (q) => q.order('employee_name')),
        selectAll('promoter_outlet_assignments', '*'),
        selectAll('org_inventory_adjustments', '*'),
        selectAll('promoter_inventory', '*'),
      ]);
      setPeople(p); setStock(i); setAssignments(a); setStockAdjustments(adj); setPromoterStock(pi);
    } catch (e) { setErr(friendly(e)); }
  }
  React.useEffect(() => { refresh(); }, []);
  const users = data.promoters.filter((u) => u.role === 'promoter');
  const filtered = useMemo(() => (people || []).filter((p) => {
    const value = (v) => v || 'Unspecified';
    const search = filters.q.toLowerCase();
    return (filters.designation === 'all' || p.designation === filters.designation)
      && (filters.state === 'all' || value(p.state_raw) === filters.state)
      && (filters.market === 'all' || value(p.market_raw) === filters.market)
      && (filters.area === 'all' || value(p.area_raw) === filters.area)
      && (filters.beat === 'all' || (p.beat_values || []).some((b) => value(b) === filters.beat))
      && (filters.tse === 'all' || (filters.tse === 'none' ? !p.mapped_tse_id : p.mapped_tse_id === filters.tse))
      && (filters.mer === 'all' || (filters.mer === 'none' ? !p.mapped_mer_id : p.mapped_mer_id === filters.mer))
      && (filters.assignment === 'all' || p.assignment_status === filters.assignment)
      && (filters.inventory === 'all' || (filters.inventory === 'with' ? stock?.some((s) => s.person_id === p.id) : !stock?.some((s) => s.person_id === p.id)))
      && (filters.active === 'all' || String(p.active) === filters.active)
      && (!search || [p.employee_name,p.mobile,p.fas_id,p.qa_employee_id,p.market_raw,p.area_raw,...(p.beat_values||[])].some((x) => String(x||'').toLowerCase().includes(search)));
  }), [people, stock, filters]);
  const distinct = (key) => [...new Set((people || []).map((p) => p[key] || 'Unspecified'))].sort();
  const fieldFilter = (key, label, opts, includeNone = false) => <select key={key} aria-label={label} value={filters[key]} onChange={(e) => setFilters({ ...filters, [key]: e.target.value })}><option value="all">All {label}</option>{includeNone && <option value="none">Unassigned</option>}{opts.map((o) => typeof o === 'string' ? <option key={o} value={o}>{o}</option> : <option key={o.id} value={o.id}>{o.employee_name}</option>)}</select>;

  async function runImport() {
    setBusy(true); setErr(''); setNotice('');
    try {
      if (!files.up || !files.mh || !files.inventory) throw new Error('Choose all three workbooks before importing.');
      const [upRows, mhRows, invRows] = await Promise.all([readSheet(files.up), readSheet(files.mh), readSheet(files.inventory)]);
      const master = [...parseUP(upRows), ...parseMH(mhRows)];
      const inventory = parseInventory(invRows);
      const result = await rpc('import_org_master_inventory', { p_master: master, p_inventory: inventory, p_run_key: runKey.trim() }, { timeoutMs: 120000 });
      setNotice(`Imported/updated ${result.master_rows} master rows; ${result.inventory_rows || 0} inventory rows processed${result.inventory_already_imported ? ' (initial inventory was already applied)' : ''}.`);
      await refresh(); await reloadData();
    } catch (e) { setErr(friendly(e)); }
    finally { setBusy(false); }
  }

  async function saveAssignment(person, field, value) {
    setErr('');
    const patch = { [field]: value || null, assignment_source: 'manual', updated_at: new Date().toISOString() };
    const { error } = await supabase.from('org_people').update(patch).eq('id', person.id);
    if (error) setErr(friendly(error)); else await refresh();
  }
  async function setOutlets(personId, outletIds) {
    setBusy(true); setErr('');
    try {
      await rpc('set_promoter_outlets', { p_promoter_id: personId, p_outlet_ids: outletIds });
      await refresh(); setNotice('Outlet permissions saved.');
    } catch (e) { setErr(friendly(e)); }
    finally { setBusy(false); }
  }
  async function linkLogin(person, authUserId) {
    if (!authUserId || (person.auth_user_id && person.auth_user_id !== authUserId)) return;
    try { await rpc('link_org_promoter', { p_person_id: person.id, p_user_id: authUserId }); await refresh(); setNotice('Promoter login linked. Initial snack allocation was seeded only if the account had no existing balance.'); }
    catch (e) { setErr(friendly(e)); }
  }
  async function toggleActive(person) {
    const { error } = await supabase.from('org_people').update({ active: !person.active, updated_at: new Date().toISOString() }).eq('id', person.id);
    if (error) setErr(friendly(error)); else await refresh();
  }
  async function saveOverride(person, field, value) {
    const normalized = norm(value);
    const patch = field === 'beat_override' ? { [field]: normalized ? normalized.split(',').map(norm).filter(Boolean) : null }
      : { [field]: normalized || null };
    const { error } = await supabase.from('org_people').update({ ...patch, updated_at: new Date().toISOString() }).eq('id', person.id);
    if (error) setErr(friendly(error)); else await refresh();
  }
  async function createPerson() {
    setErr('');
    const name = norm(newPerson.employee_name);
    if (!name) { setErr('Employee name is required.'); return; }
    const sourceKey = `ADMIN:${newPerson.designation}:${keyPart(name)}:${keyPart(newPerson.state_raw)}:${keyPart(newPerson.market_raw)}:${keyPart(newPerson.area_raw)}:${Date.now()}`;
    const { error } = await supabase.from('org_people').insert({
      designation: newPerson.designation, employee_name: name, mobile: norm(newPerson.mobile) || null, source_key: sourceKey,
      source_system: 'admin', source_ids: {}, state_raw: norm(newPerson.state_raw) || null, market_raw: norm(newPerson.market_raw) || null,
      area_raw: norm(newPerson.area_raw) || null, beat_values: norm(newPerson.beat) ? [norm(newPerson.beat)] : [], assignment_source: 'manual',
    });
    if (error) { setErr(friendly(error)); return; }
    setNewPerson({ ...newPerson, employee_name: '', mobile: '', area_raw: '', beat: '' }); await refresh(); setNotice(`${newPerson.designation} record created. Add a login/outlet assignment if the employee is a promoter.`);
  }
  async function adjustOrgStock(row, code, delta, note) {
    try {
      await rpc('adjust_org_inventory', { p_inventory_id: row.id, p_prize_code: code, p_qty_delta: Number(delta), p_note: note });
      await refresh(); setNotice('Employee inventory adjustment saved.');
    } catch (e) { setErr(friendly(e)); }
  }

  return <div className="s-page">
    <Tabs value={tab} onChange={setTab} tabs={[{ key: 'people', label: 'People & assignments' }, { key: 'outlets', label: 'Outlet access' }, { key: 'inventory', label: 'Employee inventory' }, { key: 'import', label: 'Import workbooks' }]} />
    {err && <div className="s-err">{err}</div>}{notice && <div className="s-note">{notice}</div>}
    {tab === 'people' && <>
      <Panel title="Add organizational record"><div className="s-grid2"><Field label="Designation"><select value={newPerson.designation} onChange={(e) => setNewPerson({ ...newPerson, designation: e.target.value })}><option>PROMOTER</option><option>TSE</option><option>MER</option><option>ASM</option></select></Field><Field label="Employee name"><input value={newPerson.employee_name} onChange={(e) => setNewPerson({ ...newPerson, employee_name: e.target.value })} /></Field><Field label="Mobile"><input value={newPerson.mobile} onChange={(e) => setNewPerson({ ...newPerson, mobile: e.target.value })} /></Field><Field label="Source state"><input value={newPerson.state_raw} onChange={(e) => setNewPerson({ ...newPerson, state_raw: e.target.value })} /></Field><Field label="Market"><input value={newPerson.market_raw} onChange={(e) => setNewPerson({ ...newPerson, market_raw: e.target.value })} /></Field><Field label="Area"><input value={newPerson.area_raw} onChange={(e) => setNewPerson({ ...newPerson, area_raw: e.target.value })} /></Field><Field label="Beat"><input value={newPerson.beat} onChange={(e) => setNewPerson({ ...newPerson, beat: e.target.value })} /></Field></div><button className="s-btn" onClick={createPerson}>Add record</button></Panel>
      <Panel title="Organizational directory">
      <div className="org-filters"><input value={filters.q} onChange={(e) => setFilters({ ...filters, q: e.target.value })} placeholder="Search name, ID or mobile" />{fieldFilter('designation','designation',['PROMOTER','TSE','MER','ASM'])}{fieldFilter('state','state',distinct('state_raw'))}{fieldFilter('market','market',distinct('market_raw'))}{fieldFilter('area','area',distinct('area_raw'))}{fieldFilter('beat','beat',[...new Set((people || []).flatMap((p) => p.beat_values || []))].sort())}{fieldFilter('tse','TSE',(people || []).filter((p) => p.designation==='TSE'),true)}{fieldFilter('mer','MER',(people || []).filter((p) => p.designation==='MER'),true)}{fieldFilter('assignment','assignment status',['TSE_ASSIGNED','MER_ASSIGNED','TSE_AND_MER_ASSIGNED','NO_TSE_OR_MER'])}{fieldFilter('inventory','inventory status',['with','without'])}{fieldFilter('active','active status',['true','false'])}</div>
      {people && <DataTable rows={filtered.map((p) => ({ ...p, beats: (p.beat_values || []).join(', '), linked: users.find((u) => u.id === p.auth_user_id)?.full_name || (p.auth_user_id ? 'Linked' : 'No login') }))} exportName="organizational_directory" columns={[
        { key: 'employee_name', label: 'Employee' }, { key: 'designation', label: 'Role' }, { key: 'mobile', label: 'Mobile' }, { key: 'state_raw', label: 'Source state' }, { key: 'market_raw', label: 'Source market' }, { key: 'area_raw', label: 'Source area' }, { key: 'beats', label: 'Source beat(s)' },
        { key: 'market_override', label: 'Manual market', render: (p) => <InlineEdit value={p.market_override} placeholder={p.market_raw || 'Add override'} save={(v) => saveOverride(p,'market_override',v)} /> },
        { key: 'area_override', label: 'Manual area', render: (p) => <InlineEdit value={p.area_override} placeholder={p.area_raw || 'Add override'} save={(v) => saveOverride(p,'area_override',v)} /> },
        { key: 'beat_override', label: 'Manual beats', render: (p) => <InlineEdit value={(p.beat_override || []).join(', ')} placeholder={(p.beat_values || []).join(', ') || 'Add override'} save={(v) => saveOverride(p,'beat_override',v)} /> },
        { key: 'linked', label: 'Login' },
        { key: 'auth_user_id', label: 'Link promoter login', render: (p) => p.designation !== 'PROMOTER' ? '—' : <select aria-label={`Login for ${p.employee_name}`} value={p.auth_user_id || ''} disabled={!!p.auth_user_id} onChange={(e) => linkLogin(p, e.target.value)}><option value="">No login linked</option>{users.filter((u) => !(people || []).some((x) => x.auth_user_id === u.id && x.id !== p.id)).map((u) => <option key={u.id} value={u.id}>{u.full_name} · {u.login_id}</option>)}</select> },
        { key: 'assignment_status', label: 'Assignment status' },
        { key: 'mapped_tse_id', label: 'Mapped TSE', render: (p) => p.designation !== 'PROMOTER' ? '—' : <select aria-label={`TSE for ${p.employee_name}`} value={p.mapped_tse_id || ''} onChange={(e) => saveAssignment(p, 'mapped_tse_id', e.target.value)}><option value="">None</option>{(people || []).filter((x) => x.designation === 'TSE').map((x) => <option key={x.id} value={x.id}>{x.employee_name}</option>)}</select> },
        { key: 'mapped_mer_id', label: 'Mapped MER', render: (p) => p.designation !== 'PROMOTER' ? '—' : <select aria-label={`MER for ${p.employee_name}`} value={p.mapped_mer_id || ''} onChange={(e) => saveAssignment(p, 'mapped_mer_id', e.target.value)}><option value="">None</option>{(people || []).filter((x) => x.designation === 'MER').map((x) => <option key={x.id} value={x.id}>{x.employee_name}</option>)}</select> },
        { key: 'active', label: 'Active', render: (p) => <><Badge tone={p.active ? 'green' : 'red'}>{p.active ? 'Active' : 'Inactive'}</Badge><button className="s-btn ghost sm" onClick={() => toggleActive(p)}>{p.active ? 'Deactivate' : 'Activate'}</button></> },
      ]} />}
    </Panel></>}
    {tab === 'outlets' && <Panel title="Explicit promoter outlet access"><p className="muted">The source workbooks contain no outlet-to-promoter assignments. Assign outlet access here; promoters will see only the selected outlets after login.</p>
      {people?.filter((p) => p.designation === 'PROMOTER').map((p) => { const assigned = (assignments || []).filter((a) => a.promoter_id === p.id && a.active).map((a) => a.outlet_id); return <OutletAssignment key={p.id} person={p} outlets={data.outletsFull} assigned={assigned} save={setOutlets} busy={busy} />; })}
    </Panel>}
    {tab === 'inventory' && <Panel title="Employee inventory allocations"><p className="muted">Source allocations stay separate from live consumption. Promoter adjustments are also applied to the existing promoter stock ledger when an account is linked. TSE/MER/ASM stock never transfers to promoters automatically.</p>
      {stock && <DataTable rows={stock.map((s) => { const a = stockAdjustments.filter((x) => x.org_inventory_id === s.id); const person = people?.find((p) => p.id === s.person_id); const uid = person?.auth_user_id; const id5 = data.masters.prizes.find((p) => p.code === 'SNACK5')?.id; const id10 = data.masters.prizes.find((p) => p.code === 'SNACK10')?.id; const bal = (id) => promoterStock.find((x) => x.promoter_id === uid && x.prize_id === id)?.on_hand ?? 0; return { ...s, current5: uid ? bal(id5) : s.snack5_initial + a.filter((x) => x.prize_code === 'SNACK5').reduce((n, x) => n + x.qty_delta, 0), current10: uid ? bal(id10) : s.snack10_initial + a.filter((x) => x.prize_code === 'SNACK10').reduce((n, x) => n + x.qty_delta, 0), inventory_status: (uid ? bal(id5) + bal(id10) : s.snack5_initial + s.snack10_initial) ? 'Has stock' : 'No stock' }; })} exportName="employee_inventory" columns={[
        { key: 'employee_name', label: 'Employee' }, { key: 'designation', label: 'Designation' }, { key: 'state_raw', label: 'State' }, { key: 'market_raw', label: 'Market' }, { key: 'area_raw', label: 'Area' },
        { key: 'snack5_initial', label: '₹5 initial', align: 'r' }, { key: 'current5', label: '₹5 current', align: 'r' }, { key: 'snack10_initial', label: '₹10 initial', align: 'r' }, { key: 'current10', label: '₹10 current', align: 'r' }, { key: 'inventory_status', label: 'Status' }, { key: 'fas_id', label: 'FAS ID' }, { key: 'qa_employee_id', label: 'QA Emp. ID' },
        { key: 'adjust', label: 'Adjust', noExport: true, render: (s) => <StockAdjust row={s} save={adjustOrgStock} /> },
      ]} />}
    </Panel>}
    {tab === 'import' && <Panel title="Import organizational master and initial inventory"><p>Choose the UP master, Maharashtra master, and combined inventory workbook. Master people come only from the first two files. The inventory workbook is reconciled to those records and cannot create directory people.</p>
      <div className="s-form"><Field label="Uttar Pradesh TSE / MER / Promoter master"><input type="file" accept=".xlsx,.xls" onChange={(e) => setFiles({ ...files, up: e.target.files?.[0] || null })} /></Field>
        <Field label="Maharashtra TSE / MER master"><input type="file" accept=".xlsx,.xls" onChange={(e) => setFiles({ ...files, mh: e.target.files?.[0] || null })} /></Field>
        <Field label="MH-UP inventory workbook"><input type="file" accept=".xlsx,.xls" onChange={(e) => setFiles({ ...files, inventory: e.target.files?.[0] || null })} /></Field>
        <Field label="Import run key" hint="Keep the same key to safely repeat this import. Use a new key only for a distinct inventory snapshot; existing promoter stock will never be overwritten or added twice."><input value={runKey} onChange={(e) => setRunKey(e.target.value)} /></Field>
        <p className="muted">Re-running the same key refreshes source master fields but does not reapply inventory or alter manual TSE/MER assignment, outlet assignment, or existing stock. New stock issues should use the adjustment action so promoter prize inventory stays in sync.</p>
        <button className="s-btn" disabled={busy || !files.up || !files.mh || !files.inventory} onClick={runImport}>{busy ? 'Importing…' : 'Import and reconcile'}</button>
      </div>
    </Panel>}
  </div>;
}

function OutletAssignment({ person, outlets, assigned, save, busy }) {
  const [selected, setSelected] = useState(assigned);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  React.useEffect(() => setSelected(assigned), [assigned.join('|')]);
  const filtered = outlets.filter((o) => [o.name,o.outlet_code,o.area,o.city,o.beat].some((x) => String(x || '').toLowerCase().includes(query.toLowerCase())));
  return <div className="org-outlet-row"><div><b>{person.employee_name}</b><small>{person.state_raw} · {person.market_raw || 'Market unspecified'} · {assigned.length} outlets assigned</small></div>
    <details onToggle={(e) => setOpen(e.currentTarget.open)}><summary>Manage outlets</summary>{open && <><input className="org-outlet-search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search outlet, code, area or beat" /><div className="org-outlet-list">{filtered.map((o) => <label key={o.id}><input type="checkbox" checked={selected.includes(o.id)} onChange={(e) => setSelected(e.target.checked ? [...selected, o.id] : selected.filter((id) => id !== o.id))} />{o.name}<small>{o.area} · {o.outlet_code}</small></label>)}{!filtered.length && <p className="muted">No matching outlets.</p>}</div><button className="s-btn sm" disabled={busy} onClick={() => save(person.id, selected)}>Save outlet access</button></>}</details>
  </div>;
}

function StockAdjust({ row, save }) {
  const [code, setCode] = useState('SNACK5');
  const [delta, setDelta] = useState('');
  const [note, setNote] = useState('');
  return <div className="org-stock-adjust"><select value={code} onChange={(e) => setCode(e.target.value)} aria-label="Snack type"><option value="SNACK5">₹5</option><option value="SNACK10">₹10</option></select><input type="number" value={delta} onChange={(e) => setDelta(e.target.value)} placeholder="± qty" aria-label="Stock quantity change" /><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Reason" aria-label="Adjustment reason" /><button className="s-btn sm" disabled={!Number(delta) || !note.trim()} onClick={() => { save(row, code, delta, note); setDelta(''); setNote(''); }}>Save</button></div>;
}

function InlineEdit({ value, placeholder, save }) {
  const [draft, setDraft] = useState(value || '');
  React.useEffect(() => setDraft(value || ''), [value]);
  return <input className="org-inline-edit" value={draft} placeholder={placeholder} onChange={(e) => setDraft(e.target.value)} onBlur={() => { if (draft !== (value || '')) save(draft); }} />;
}
