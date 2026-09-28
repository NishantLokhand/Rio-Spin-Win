import React, { useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { selectAll, friendly } from '../lib/api.js';
import { useAsync, Panel, Loading, DataTable, Modal, Field, Badge, Tabs } from './ui.jsx';

async function adminCall(body) {
  const { data, error } = await supabase.functions.invoke('admin-users', { body });
  if (error) {
    let msg = error.message;
    try { const j = await error.context?.json?.(); if (j?.error) msg = j.error; } catch { /* ignore */ }
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
    const [users, promoters] = await Promise.all([selectAll('app_users', '*', (q) => q.order('full_name')), selectAll('promoters', '*')]);
    return users.map((u) => ({ ...u, ...(promoters.find((p) => p.user_id === u.id) || {}) }));
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
      <Tabs value={role} onChange={setRole} tabs={[{ key: 'promoter', label: 'Promoters' }, { key: 'supervisor', label: 'Supervisors' }, { key: 'admin', label: 'Admins' }]} />
      {err && <div className="s-err">{err}</div>}
      <Panel title={`${role[0].toUpperCase() + role.slice(1)}s`} actions={<button className="s-btn sm" onClick={() => setEdit({ role, is_active: true, promoter_type: 'permanent' })}>+ Create {role}</button>}>
        <DataTable rows={us.data.filter((u) => u.role === role).map((u) => ({ ...u, supervisor: supName(u.supervisor_id) }))} exportName={`${role}s`} columns={[
          { key: 'full_name', label: 'Name' }, { key: 'login_id', label: 'Login (mobile / username)' }, { key: 'mobile', label: 'Mobile' },
          ...(role === 'promoter' ? [{ key: 'promoter_code', label: 'Promoter ID' }, { key: 'promoter_type', label: 'Type' },
            { key: 'agency_name', label: 'Agency' }, { key: 'supervisor', label: 'Supervisor' }] : []),
          ...(role === 'supervisor' ? [{ key: 'can_approve_outlets', label: 'Approves outlets', fmt: (v) => (v ? 'Yes' : 'No') }] : []),
          ...(role === 'admin' ? [{ key: 'can_override_cost_target', label: 'Can override cost target', fmt: (v) => (v ? 'Yes' : 'No') }] : []),
          { key: 'is_active', label: 'Status', noExport: true, render: (u) => <Badge tone={u.is_active ? 'green' : 'red'}>{u.is_active ? 'Active' : 'Disabled'}</Badge> },
          { key: 'a', label: '', noExport: true, render: (u) => (
            <div className="row-actions">
              <button className="s-btn ghost sm" onClick={() => setEdit(u)}>Edit</button>
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
  const [f, setF] = useState({ ...u });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });

  async function save() {
    setBusy(true); setErr('');
    try {
      if (isNew) {
        if (!/^\S{6,}$/.test(f.pin || '')) throw new Error('PIN must be at least 6 characters');
        await adminCall({ action: 'create', role: f.role, login_id: f.login_id, pin: f.pin, full_name: f.full_name, mobile: f.mobile || null,
          can_approve_outlets: !!f.can_approve_outlets, can_override_cost_target: !!f.can_override_cost_target,
          promoter: f.role === 'promoter' ? { promoter_code: f.promoter_code, promoter_type: f.promoter_type, agency_name: f.agency_name || null,
            supervisor_id: f.supervisor_id || null, home_state_id: f.home_state_id || null } : null });
      } else {
        const { error } = await supabase.from('app_users').update({ full_name: f.full_name, mobile: f.mobile || null,
          can_approve_outlets: !!f.can_approve_outlets, can_override_cost_target: !!f.can_override_cost_target }).eq('id', u.id);
        if (error) throw error;
        if (u.role === 'promoter') {
          const { error: e2 } = await supabase.from('promoters').update({ promoter_code: f.promoter_code, promoter_type: f.promoter_type,
            agency_name: f.agency_name || null, supervisor_id: f.supervisor_id || null, home_state_id: f.home_state_id || null }).eq('user_id', u.id);
          if (e2) throw e2;
        }
      }
      onClose(true);
    } catch (e) { setErr(friendly(e)); setBusy(false); }
  }

  return (
    <Modal title={isNew ? `Create ${f.role}` : `Edit ${u.full_name}`} onClose={() => onClose(false)}>
      <div className="s-form">
        <Field label="Full name"><input value={f.full_name || ''} onChange={set('full_name')} /></Field>
        {isNew && <Field label="Login ID" hint="Mobile number (promoters) or username. Cannot be changed later."><input value={f.login_id || ''} onChange={set('login_id')} /></Field>}
        {isNew && <Field label="PIN / password" hint="At least 6 characters. Share it privately."><input value={f.pin || ''} onChange={set('pin')} /></Field>}
        <Field label="Mobile"><input value={f.mobile || ''} onChange={set('mobile')} /></Field>
        {f.role === 'promoter' && <>
          <div className="s-grid2">
            <Field label="Promoter ID / code"><input value={f.promoter_code || ''} onChange={set('promoter_code')} /></Field>
            <Field label="Promoter type"><select value={f.promoter_type || 'permanent'} onChange={set('promoter_type')}>
              <option value="permanent">Permanent</option><option value="temporary">Temporary</option>
              <option value="spot_selling">Spot-selling</option><option value="agency">Agency</option></select></Field>
            <Field label="Agency (if any)"><input value={f.agency_name || ''} onChange={set('agency_name')} /></Field>
            <Field label="Supervisor"><select value={f.supervisor_id || ''} onChange={set('supervisor_id')}>
              <option value="">— none —</option>{sups.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}</select></Field>
            <Field label="Home state"><select value={f.home_state_id || ''} onChange={set('home_state_id')}>
              <option value="">—</option>{data.masters.states.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
          </div>
        </>}
        {f.role === 'supervisor' && <label className="check"><input type="checkbox" checked={!!f.can_approve_outlets} onChange={set('can_approve_outlets')} /> Authorised to approve new outlets</label>}
        {f.role === 'admin' && <label className="check"><input type="checkbox" checked={!!f.can_override_cost_target} onChange={set('can_override_cost_target')} /> Authorised to override the cost-per-spin target</label>}
        {err && <div className="s-err">{err}</div>}
        <div className="s-actions"><button className="s-btn ghost" onClick={() => onClose(false)}>Cancel</button>
          <button className="s-btn" disabled={busy} onClick={save}>{busy ? 'Saving…' : 'Save'}</button></div>
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
