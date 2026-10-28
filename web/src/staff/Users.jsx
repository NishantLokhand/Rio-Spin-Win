import React, { useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { useAsync, Panel, Loading, DataTable, Modal, Field, Badge, Tabs } from './ui.jsx';

async function adminCall(body) {
  const { data, error } = await supabase.functions.invoke('admin-users', { body });
  if (error) {
    let msg = error.message;
    try {
      const response = error.context;
      if (response) {
        const text = await (response.clone ? response.clone().text() : Promise.resolve(''));
        if (text) {
          try { const j = JSON.parse(text); if (j?.error) msg = j.error; else if (j?.message) msg = j.message; }
          catch { if (text.trim()) msg = text.trim(); }
        }
      }
    } catch { /* keep the SDK message when the response body is unavailable */ }
    throw new Error(msg);
  }
  if (data?.error) throw new Error(data.error);
  return data;
}

export default function Users({ data, reloadData }) {
  const [role, setRole] = useState('promoter');
  const [edit, setEdit] = useState(null);
  const [pin, setPin] = useState(null);
  const [err, setErr] = useState('');
  const us = useAsync(async () => {
    const [users, promoters, people, deleted] = await Promise.all([selectAll('app_users', '*', (q) => q.order('full_name')), selectAll('promoters', '*'), selectAll('org_people', '*'), rpc('get_deleted_field_users')]);
    // Disabled/deleted users remain in the database for history, but do not
    // appear in the active Users administration lists.
    return users.filter((u) => u.is_active && !deleted.includes(u.id)).map((u) => ({ ...u, ...(promoters.find((p) => p.user_id === u.id) || {}), org_profile: people.find((p) => p.auth_user_id === u.id) }));
  }, []);
  if (!us.data) return <div className="s-page"><Loading state={us} /></div>;
  const sups = us.data.filter((u) => u.role === 'supervisor');
  const supName = (id) => sups.find((s) => s.id === id)?.full_name;

  async function toggle(u) {
    if (!confirm(`${u.is_active ? 'Disable' : 'Enable'} ${u.full_name}?${u.is_active ? ' They will be signed out and cannot log in.' : ''}`)) return;
    try { await adminCall({ action: 'set_active', user_id: u.id, active: !u.is_active }); us.reload(); reloadData(); }
    catch (e) { setErr(friendly(e)); }
  }

  return (
    <div className="s-page">
      <Tabs value={role} onChange={setRole} tabs={[{ key: 'promoter', label: 'Field team' }, { key: 'supervisor', label: 'Supervisors' }, { key: 'admin', label: 'Admins' }]} />
      {err && <div className="s-err">{err}</div>}
      <Panel title={role === 'promoter' ? 'Field team — Promoters, TSEs & MERs' : `${role[0].toUpperCase() + role.slice(1)}s`} actions={<button className="s-btn sm" onClick={() => setEdit({ role, is_active: true, promoter_type: 'permanent', designation: 'PROMOTER' })}>+ Create {role === 'promoter' ? 'field user' : role}</button>}>
        <DataTable rows={us.data.filter((u) => u.role === role).map((u) => ({ ...u, supervisor: supName(u.supervisor_id),
          city: u.org_profile?.market_override ?? u.org_profile?.market_raw ?? '',
          area: u.org_profile?.area_override ?? u.org_profile?.area_raw ?? '',
          state: u.org_profile?.state_raw ?? '',
        }))} exportName={`${role}s`} columns={[
          { key: 'full_name', label: 'Name' }, { key: 'edit_user', label: 'Edit', noExport: true, render: (u) => <button className="s-btn ghost sm" onClick={() => setEdit(u)}>Edit</button> }, { key: 'login_id', label: 'Login (mobile / username)' }, { key: 'mobile', label: 'Mobile' },
          ...(role === 'promoter' ? [{ key: 'designation', label: 'Field role', render: (u) => u.org_profile?.designation || 'Not linked' }, { key: 'org_link', label: 'Organization', render: (u) => <Badge tone={u.org_profile?.active ? 'green' : 'red'}>{u.org_profile?.active ? 'Linked' : 'Needs linking'}</Badge> }, { key: 'promoter_code', label: 'Promoter ID' },
            { key: 'state', label: 'State' }, { key: 'city', label: 'City' }, { key: 'area', label: 'Area' },
            { key: 'agency_name', label: 'Agency' }, { key: 'supervisor', label: 'Supervisor' }] : []),
          ...(role === 'supervisor' ? [{ key: 'can_approve_outlets', label: 'Approves outlets', fmt: (v) => (v ? 'Yes' : 'No') }] : []),
          ...(role === 'admin' ? [{ key: 'can_override_cost_target', label: 'Can override cost target', fmt: (v) => (v ? 'Yes' : 'No') }] : []),
          { key: 'is_active', label: 'Status', noExport: true, render: (u) => <Badge tone={u.is_active ? 'green' : 'red'}>{u.is_active ? 'Active' : 'Disabled'}</Badge> },
          { key: 'a', label: '', noExport: true, render: (u) => (
            <div className="row-actions">
              <button className="s-btn ghost sm" onClick={() => setPin(u)}>Reset PIN</button>
              <button className={`s-btn sm ${u.is_active ? 'danger' : ''}`} onClick={() => toggle(u)}>{u.is_active ? 'Disable' : 'Enable'}</button>
            </div>) },
        ]} />
      </Panel>
      {edit && <UserModal u={edit} data={data} sups={sups} onClose={(c) => { setEdit(null); if (c) { us.reload(); reloadData(); } }} />}
      {pin && <PinModal u={pin} onClose={() => setPin(null)} />}
    </div>
  );
}

function UserModal({ u, data, sups, onClose }) {
  const isNew = !u.id;
  const [f, setF] = useState(() => ({ ...u,
    designation: u.org_profile?.designation || u.designation || 'PROMOTER',
    home_state_id: u.home_state_id || data.masters.states.find((s) => s.name.toLowerCase() === (u.org_profile?.state_raw || '').toLowerCase())?.id || '',
    mobile: u.mobile ?? u.org_profile?.mobile ?? '',
    market: u.org_profile?.market_override ?? u.org_profile?.market_raw ?? '',
    area: u.org_profile?.area_override ?? u.org_profile?.area_raw ?? '',
    territory_id: u.org_profile?.territory_id || '',
    mapped_tse_id: u.org_profile?.mapped_tse_id || '', mapped_mer_id: u.org_profile?.mapped_mer_id || '',
    beat: (u.org_profile?.beat_override ?? u.org_profile?.beat_values ?? []).join(', '),
  }));
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [deleting, setDeleting] = useState(false), [confirmLogin, setConfirmLogin] = useState('');
  const people = useAsync(() => f.role === 'promoter' ? selectAll('org_people', '*', (q) => q.order('employee_name')) : Promise.resolve([]), []);
  const available = (people.data || []).filter((p) => p.active && !p.auth_user_id && ['PROMOTER', 'TSE', 'MER'].includes(p.designation));
  function choosePerson(e) {
    const person = available.find((p) => p.id === e.target.value);
    setF({ ...f, person_id: person?.id || '', ...(person ? { full_name: person.employee_name, mobile: person.mobile || '', login_id: person.mobile || f.login_id, designation: person.designation, home_state_id: data.masters.states.find((s) => s.name.toLowerCase() === (person.state_raw || '').toLowerCase() || s.code.toLowerCase() === (person.state_raw || '').toLowerCase() || (s.code === 'MH' && person.state_raw === 'MAHARASHTRA_ROM'))?.id || '' } : {}) });
  }
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });

  async function save() {
    setBusy(true); setErr('');
    try {
      if (f.role === 'promoter' && !f.home_state_id && !(u.org_profile?.state_raw || (people.data || []).find((p) => p.id === f.person_id)?.state_raw)) throw new Error('Select a Home state: Maharashtra or Uttar Pradesh.');
      if (isNew) {
        if (!/^\S{6,}$/.test(f.pin || '')) throw new Error('PIN must be at least 6 characters');
        await adminCall({ action: 'create', role: f.role, login_id: f.login_id, pin: f.pin, full_name: f.full_name, mobile: f.mobile || null,
          can_approve_outlets: !!f.can_approve_outlets, can_override_cost_target: !!f.can_override_cost_target,
          promoter: f.role === 'promoter' ? { promoter_code: f.promoter_code, promoter_type: f.promoter_type, agency_name: f.agency_name || null,
            supervisor_id: f.supervisor_id || null, home_state_id: f.home_state_id || null } : null,
          organization: f.role === 'promoter' ? { person_id: f.person_id || null, designation: f.designation || 'PROMOTER',
            state: data.masters.states.find((s) => s.id === f.home_state_id)?.name || null, market: f.market || null, area: f.area || null, beat: f.beat || null } : null });
      } else if (u.role === 'promoter') {
        await rpc('update_field_user', { p_user_id: u.id, p_values: {
          full_name: f.full_name, mobile: f.mobile || '', designation: f.designation,
          home_state_id: f.home_state_id, promoter_code: f.promoter_code,
          promoter_type: f.promoter_type, agency_name: f.agency_name || '',
          supervisor_id: f.supervisor_id || '', market: f.market, area: f.area,
          territory_id: f.territory_id || '', mapped_tse_id: f.mapped_tse_id || '', mapped_mer_id: f.mapped_mer_id || '',
          beats: String(f.beat || '').split(',').map((v) => v.trim()).filter(Boolean),
        } });
      } else {
        const { error } = await supabase.from('app_users').update({ full_name: f.full_name, mobile: f.mobile || null,
          can_approve_outlets: !!f.can_approve_outlets, can_override_cost_target: !!f.can_override_cost_target }).eq('id', u.id);
        if (error) throw error;
      }
      onClose(true);
    } catch (e) { setErr(friendly(e)); setBusy(false); }
  }

  async function remove() {
    setBusy(true); setErr('');
    try {
      await rpc('delete_field_user', { p_user_id: u.id, p_confirm_login: confirmLogin });
      onClose(true);
    } catch (e) { setErr(friendly(e)); setBusy(false); }
  }

  return (
    <Modal title={isNew ? f.role === 'promoter' ? 'Add field team member' : `Create ${f.role}` : `Edit ${u.full_name}`} onClose={() => { if (!busy) onClose(false); }}>
      <div className="s-form">
        {isNew && f.role === 'promoter' && <>
          <p className="muted">Create a login and linked organizational profile together. The user can select active outlets immediately; prize stock is managed separately.</p>
          <Field label="Organizational record" hint="Select an imported employee, or create their record here.">
            <select value={f.person_id || ''} onChange={choosePerson} disabled={people.loading || !!people.error}>
              <option value="">Create new organizational record</option>
              {available.map((p) => <option key={p.id} value={p.id}>{p.employee_name} · {p.designation} · {p.mobile || p.state_raw || 'No mobile'}</option>)}
            </select>
          </Field>
          {people.error && <div className="s-err">Could not load organizational records. <button className="s-btn ghost sm" onClick={people.reload}>Retry</button></div>}
          <Field label="Field role"><select value={f.designation || 'PROMOTER'} onChange={set('designation')} disabled={!!f.person_id}>
            <option value="PROMOTER">Promoter</option><option value="TSE">TSE</option><option value="MER">MER</option>
          </select></Field>
        </>}
        {!isNew && <Field label="Login ID" hint="Login identifiers remain fixed; mobile contact details can be edited below."><input value={f.login_id || ''} readOnly /></Field>}
        {!isNew && f.role === 'promoter' && <Field label="Field role"><select value={f.designation} onChange={set('designation')}>
          <option value="PROMOTER">Promoter</option><option value="TSE">TSE</option><option value="MER">MER</option>
        </select></Field>}
        <Field label="Full name"><input value={f.full_name || ''} onChange={set('full_name')} /></Field>
        {isNew && <Field label="Login ID" hint="Mobile number (promoters) or username. Cannot be changed later."><input value={f.login_id || ''} onChange={set('login_id')} /></Field>}
        {isNew && <Field label="PIN / password" hint="At least 6 characters. Share it privately."><input type="password" autoComplete="new-password" value={f.pin || ''} onChange={set('pin')} /></Field>}
        {f.role === 'promoter' && <Field label="Home state" hint="Required for outlet request approvals."><select value={f.home_state_id || ''} onChange={(e) => setF({ ...f, home_state_id: e.target.value, territory_id: '' })}>
          <option value="">Select state</option>{data.masters.states.filter((s) => ['MH','UP'].includes(s.code)).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>}
        {(!isNew || f.role !== 'promoter') && <Field label="Mobile"><input value={f.mobile || ''} onChange={set('mobile')} /></Field>}
        {f.role === 'promoter' && <details open={isNew ? undefined : true}><summary>Optional details — market, area, state and supervisor</summary>
          <Field label="Mobile (if different from login)"><input value={f.mobile || ''} onChange={set('mobile')} /></Field>
          <div className="s-grid2">
            <Field label="Employee code" hint="Optional for new users; generated automatically if blank."><input value={f.promoter_code || ''} onChange={set('promoter_code')} /></Field>
            <Field label="Promoter type"><select value={f.promoter_type || 'permanent'} onChange={set('promoter_type')}>
              <option value="permanent">Permanent</option><option value="temporary">Temporary</option>
              <option value="spot_selling">Spot-selling</option><option value="agency">Agency</option></select></Field>
            <Field label="Agency (if any)"><input value={f.agency_name || ''} onChange={set('agency_name')} /></Field>
            <Field label="Supervisor"><select value={f.supervisor_id || ''} onChange={set('supervisor_id')}>
              <option value="">— none —</option>{sups.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}</select></Field>
            <Field label="Home state"><select value={f.home_state_id || ''} onChange={(e) => setF({ ...f, home_state_id: e.target.value, territory_id: '' })}>
              <option value="">—</option>{data.masters.states.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
          </div>
        {((isNew && !f.person_id) || (!isNew && u.org_profile)) && <div className="s-grid2">
          <Field label="City / Market"><input value={f.market || ''} onChange={set('market')} /></Field>
          <Field label="Area"><input value={f.area || ''} onChange={set('area')} /></Field>
          <Field label="Beats / routes (comma separated)"><input value={f.beat || ''} onChange={set('beat')} /></Field>
          {!isNew && <>
            <Field label="Territory"><select value={f.territory_id || ''} onChange={set('territory_id')}>
              <option value="">Not assigned</option>{data.masters.territories.filter((t) => !f.home_state_id || t.state_id === f.home_state_id).map((t) => <option key={t.id} value={t.id}>{t.name} ({t.code})</option>)}
            </select></Field>
            {f.designation === 'PROMOTER' && ['TSE', 'MER'].map((designation) => <Field key={designation} label={`Mapped ${designation}`}>
              <select value={f[`mapped_${designation.toLowerCase()}_id`] || ''} onChange={set(`mapped_${designation.toLowerCase()}_id`)}>
                <option value="">None</option>{(people.data || []).filter((p) => p.designation === designation).map((p) => <option key={p.id} value={p.id}>{p.employee_name}{!p.active ? ' (inactive)' : ''}</option>)}
              </select>
            </Field>)}
          </>}
        </div>}
        {!isNew && !u.org_profile && <p className="muted">Link this user to an organizational record in Organization & Inventory to edit Market and Area.</p>}
        </details>}
        {f.role === 'supervisor' && <label className="check"><input type="checkbox" checked={!!f.can_approve_outlets} onChange={set('can_approve_outlets')} /> Authorised to approve new outlets</label>}
        {f.role === 'admin' && <label className="check"><input type="checkbox" checked={!!f.can_override_cost_target} onChange={set('can_override_cost_target')} /> Authorised to override the cost-per-spin target</label>}
        {err && <div className="s-err">{err}</div>}
        {!isNew && u.role === 'promoter' && <div>
          {!deleting ? <button className="s-btn danger" disabled={busy} onClick={() => { setDeleting(true); setErr(''); }}>Delete user</button> : <>
            <p><strong>Delete {u.full_name} ({u.login_id})?</strong> This removes the user from Users and reports and blocks app access. Sales, spins and stock history are retained. The login ID stays reserved.</p>
            <Field label={`Type ${u.login_id} to confirm deletion`}><input aria-label="Confirm delete login ID" value={confirmLogin} onChange={(e) => setConfirmLogin(e.target.value)} disabled={busy} autoComplete="off" /></Field>
            <div className="s-actions"><button className="s-btn ghost" disabled={busy} onClick={() => { setDeleting(false); setConfirmLogin(''); }}>Keep user</button>
              <button className="s-btn danger" disabled={busy || confirmLogin !== u.login_id} onClick={remove}>{busy ? 'Deleting…' : 'Confirm delete user'}</button></div>
          </>}
        </div>}
        <div className="s-actions"><button className="s-btn ghost" disabled={busy} onClick={() => onClose(false)}>Cancel</button>
          <button className="s-btn" disabled={busy || deleting || (isNew && f.role === 'promoter' && (people.loading || !!people.error))} onClick={save}>{busy ? 'Working…' : isNew && f.role === 'promoter' ? 'Create linked user' : 'Save'}</button></div>
      </div>
    </Modal>
  );
}

function PinModal({ u, onClose }) {
  const [pin, setPin] = useState('');
  const [msg, setMsg] = useState('');
  async function save() {
    try { await adminCall({ action: 'reset_pin', user_id: u.id, pin }); setMsg('PIN updated ✓'); }
    catch (e) { setMsg(friendly(e)); }
  }
  return (
    <Modal title={`Reset PIN — ${u.full_name}`} onClose={onClose}>
      <div className="s-form">
        <Field label="New PIN (min 6 characters)"><input value={pin} onChange={(e) => setPin(e.target.value)} /></Field>
        {msg && <div className="s-note">{msg}</div>}
        <div className="s-actions"><button className="s-btn" disabled={pin.length < 6} onClick={save}>Set PIN</button></div>
      </div>
    </Modal>
  );
}
