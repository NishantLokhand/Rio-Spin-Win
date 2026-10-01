import React, { useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, friendly } from '../lib/api.js';
import { useAsync, Panel, Loading, DataTable, Tabs, Modal, Field, fmt } from './ui.jsx';

export default function OutletRequests({ data, reloadData }) {
  const [status, setStatus] = useState('pending');
  const [open, setOpen] = useState(null);
  const reqs = useAsync(async () => {
    const { data: rows, error } = await supabase.from('outlet_requests')
      .select('id,promoter_id,suggested_tse_id,status,created_at,outlet_name,area,city,ref_code,note,review_note')
      .eq('status', status).order('created_at', { ascending: false });
    if (error) throw error; return rows;
  }, [status]);
  const users = Object.fromEntries(data.promoters.map((u) => [u.id, u.full_name]));
  const tses = Object.fromEntries(data.masters.tses.map((t) => [t.id, t]));
  const canApprove = data.role === 'admin' || data.profile.can_approve_outlets;

  return (
    <div className="s-page">
      <Tabs value={status} onChange={setStatus} tabs={[{ key: 'pending', label: 'Pending' }, { key: 'approved', label: 'Approved' }, { key: 'rejected', label: 'Rejected' }]} />
      {!canApprove && <div className="s-note">You can view requests but are not authorised to approve outlets.</div>}
      <Panel>
        {!reqs.data ? <Loading state={reqs} /> : (
          <DataTable rows={reqs.data.map((r) => ({ ...r, promoter: users[r.promoter_id], tse: tses[r.suggested_tse_id]?.name }))}
            exportName={`outlet_requests_${status}`} columns={[
              { key: 'created_at', label: 'Requested', fmt: fmt.dt }, { key: 'promoter', label: 'Promoter' },
              { key: 'outlet_name', label: 'Outlet name' }, { key: 'area', label: 'Area' }, { key: 'city', label: 'City' },
              { key: 'ref_code', label: 'Ref code' }, { key: 'tse', label: 'Suggested TSE' }, { key: 'note', label: 'Note' },
              { key: 'review_note', label: 'Review note' },
              ...(status === 'pending' && canApprove ? [{ key: 'act', label: '', noExport: true,
                render: (r) => <button className="s-btn sm" onClick={() => setOpen(r)}>Review</button> }] : []),
            ]} empty="No requests" />
        )}
      </Panel>
      {open && <ReviewModal req={open} data={data} onClose={(c) => { setOpen(null); if (c) { reqs.reload(); reloadData(); } }} />}
    </div>
  );
}

function ReviewModal({ req, data, onClose }) {
  const [f, setF] = useState({ name: req.outlet_name, area: req.area || '', city: req.city || '', code: req.ref_code || '', tse: req.suggested_tse_id || '', distributor: '', note: '' });
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const similar = data.outletsFull.filter((o) => o.name.toLowerCase().includes(req.outlet_name.toLowerCase().split(' ')[0])).slice(0, 5);

  async function decide(approve) {
    try {
      await rpc('review_outlet_request', { p_request_id: req.id, p_approve: approve, p_tse_id: f.tse || null, p_outlet_code: f.code || null,
        p_note: f.note || null, p_name: f.name, p_area: f.area, p_city: f.city, p_distributor: f.distributor || null });
      onClose(true);
    } catch (e) { setErr(friendly(e)); }
  }

  return (
    <Modal title="Review outlet request" onClose={() => onClose(false)}>
      <div className="s-form">
        {similar.length > 0 && <div className="s-note">Possible duplicates: {similar.map((o) => `${o.name} (${o.outlet_code}, ${o.area || ''})`).join('; ')}</div>}
        <Field label="Outlet name"><input value={f.name} onChange={set('name')} /></Field>
        <div className="s-grid2">
          <Field label="Area"><input value={f.area} onChange={set('area')} /></Field>
          <Field label="City"><input value={f.city} onChange={set('city')} /></Field>
          <Field label="Outlet code" hint="Leave blank to auto-generate"><input value={f.code} onChange={set('code')} /></Field>
          <Field label="Distributor"><input value={f.distributor} onChange={set('distributor')} /></Field>
        </div>
        <Field label="Mapped TSE">
          <select value={f.tse} onChange={set('tse')}>
            <option value="">— select —</option>
            {data.masters.tses.map((t) => <option key={t.id} value={t.id}>{t.name} ({t.code})</option>)}
          </select>
        </Field>
        <Field label="Review note"><input value={f.note} onChange={set('note')} /></Field>
        {err && <div className="s-err">{err}</div>}
        <div className="s-actions">
          <button className="s-btn danger" onClick={() => decide(false)}>Reject</button>
          <button className="s-btn" disabled={!f.tse} onClick={() => decide(true)}>Approve &amp; add to Outlet Master</button>
        </div>
      </div>
    </Modal>
  );
}
