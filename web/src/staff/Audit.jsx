import React, { useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, friendly } from '../lib/api.js';
import { useAsync, Panel, Loading, DataTable, fmt } from './ui.jsx';

const ACTIONS = ['', 'SPIN', 'SALE_RECORDED', 'PRIZE_HANDED_OVER', 'SALE_CANCELLED', 'SPIN_RESOLVED', 'PRIZE_DEFERRED', 'PRIZE_SUBSTITUTED',
  'POOL_CREATED', 'POOL_VOIDED', 'PRIZE_CONFIG_SAVED', 'STOCK_ISSUE', 'STOCK_RETURN', 'STOCK_DAMAGED', 'STOCK_MISSING', 'STOCK_ADJUSTMENT',
  'OUTLET_SELECTED', 'OUTLET_REQUESTED', 'OUTLET_REQUEST_APPROVED', 'OUTLET_REQUEST_REJECTED', 'OUTLET_MASTER_UPLOAD',
  'FLAG_RAISED', 'FLAG_REVIEWED', 'MASTER_INSERT', 'MASTER_UPDATE'];

export default function Audit() {
  const [action, setAction] = useState('');
  const [q, setQ] = useState('');
  const [verify, setVerify] = useState(null);
  const log = useAsync(async () => {
    let query = supabase.from('audit_logs').select('*').order('id', { ascending: false }).limit(500);
    if (action) query = query.eq('action', action);
    if (q) query = query.or(`entity_id.eq.${q},details->>spin_code.eq.${q},details->>sale_id.eq.${q}`);
    const { data, error } = await query;
    if (error) throw error; return data;
  }, [action, q]);

  async function check() {
    setVerify({ busy: true });
    try { setVerify(await rpc('verify_audit_chain')); } catch (e) { setVerify({ error: friendly(e) }); }
  }

  return (
    <div className="s-page">
      <Panel title="Tamper check" actions={<button className="s-btn sm" onClick={check}>Verify hash chain</button>}>
        <p className="muted pad">Every audit record is chained to the previous one with SHA-256. Records cannot be edited or deleted; any change to history breaks the chain.</p>
        {verify?.busy && <div className="s-note">Verifying…</div>}
        {verify?.intact === true && <div className="s-ok">✓ Chain intact — {verify.checked} records verified.</div>}
        {verify?.intact === false && <div className="s-err">✗ Chain broken at record #{verify.broken_at_id}.</div>}
        {verify?.error && <div className="s-err">{verify.error}</div>}
      </Panel>
      <div className="filterbar"><div className="fb-dims">
        <select value={action} onChange={(e) => setAction(e.target.value)}>{ACTIONS.map((a) => <option key={a} value={a}>{a || 'All actions'}</option>)}</select>
        <input className="s-search" placeholder="Entity / sale / spin id" value={q} onChange={(e) => setQ(e.target.value.trim())} />
      </div></div>
      <Panel title="Audit log (latest 500)">
        {!log.data ? <Loading state={log} /> : (
          <DataTable rows={log.data} exportName="audit_log" maxHeight="65vh" columns={[
            { key: 'id', label: '#', align: 'r' }, { key: 'at', label: 'Time', fmt: fmt.dt }, { key: 'actor_role', label: 'Role' },
            { key: 'action', label: 'Action' }, { key: 'entity', label: 'Entity' }, { key: 'entity_id', label: 'Entity ID' },
            { key: 'details', label: 'Details', fmt: (v) => <code className="json">{JSON.stringify(v)}</code> },
            { key: 'hash', label: 'Hash', fmt: (v) => <code>{String(v).slice(0, 10)}…</code> },
          ]} />
        )}
      </Panel>
    </div>
  );
}
