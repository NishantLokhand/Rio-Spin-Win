import React, { useMemo, useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, selectAll, friendly } from '../lib/api.js';
import { istToday } from '../lib/store.js';
import { useAsync, Panel, Loading, DataTable, Modal, Field, Badge, fmt } from './ui.jsx';

export default function Promoters({ data }) {
  const today = istToday();
  const st = useAsync(async () => {
    const [promoters, inv, sessions, pending, activity, configItems] = await Promise.all([
      selectAll('promoters', '*'),
      selectAll('promoter_inventory', '*'),
      selectAll('promoter_sessions', '*', (q) => q.eq('work_date', today)),
      selectAll('spins', 'id,spin_code,promoter_id,prize_name,created_at,sale_id', (q) => q.eq('redemption_status', 'pending')),
      rpc('report_summary', { p_group: 'promoter', p_filters: { date_from: today, date_to: today } }),
      selectAll('prize_config_items', 'config_id,prize_id,quantity,prize_configs!inner(is_active,state_id)', (q) => q.eq('prize_configs.is_active', true)),
    ]);
    return { promoters, inv, sessions, pending, activity, configItems };
  }, []);
  const [modal, setModal] = useState(null);
  const prizes = data.masters.prizes;
  const users = Object.fromEntries(data.promoters.map((u) => [u.id, u]));
  const outlets = Object.fromEntries(data.outletsFull.map((o) => [o.id, o]));

  const rows = useMemo(() => {
    if (!st.data) return [];
    const { promoters, inv, sessions, pending, activity } = st.data;
    return promoters.filter((p) => users[p.user_id]).map((p) => {
      const u = users[p.user_id];
      const a = activity.find((x) => x.key === p.user_id) || {};
      const s = sessions.find((x) => x.promoter_id === p.user_id);
      const stock = Object.fromEntries(prizes.map((pr) => {
        const i = inv.find((x) => x.promoter_id === p.user_id && x.prize_id === pr.id);
        return [pr.id, i ? i.on_hand : 0];
      }));
      return { id: p.user_id, name: u.full_name, code: p.promoter_code, type: p.promoter_type, active: u.is_active,
        outlet: s ? outlets[s.outlet_id]?.name : null, spins: a.spins || 0, cost: a.giveaway_cost || 0, avg: a.avg_cost,
        pending: pending.filter((x) => x.promoter_id === p.user_id), stock };
    });
  }, [st.data, prizes, users, outlets]);

  if (!st.data) return <div className="s-page"><Loading state={st} /></div>;
  const defaultKit = Object.fromEntries(st.data.configItems.filter((c) => !c.prize_configs.state_id).map((c) => [c.prize_id, c.quantity]));

  return (
    <div className="s-page">
      <Panel title={`Promoters — today ${fmt.date(today)}`} actions={<button className="s-btn ghost sm" onClick={st.reload}>↻ Refresh</button>}>
        <DataTable rows={rows} exportName="promoter_stock" columns={[
          { key: 'name', label: 'Promoter', render: (r) => <><b>{r.name}</b><br /><small className="muted">{r.code} · {r.type}</small>{!r.active && <> <Badge tone="red">disabled</Badge></>}</> },
          { key: 'outlet', label: 'Current outlet', fmt: (v) => v || <span className="muted">not started</span> },
          { key: 'spins', label: 'Spins today', align: 'r' },
          { key: 'cost', label: 'Cost', align: 'r', fmt: fmt.inr },
          ...prizes.map((pr) => ({ key: `stock_${pr.id}`, label: pr.short_name, align: 'r', noExport: true,
            render: (r) => <span className={r.stock[pr.id] <= 1 ? 'txt-bad' : ''}>{r.stock[pr.id]}</span> })),
          { key: 'pending', label: 'Pending', noExport: true, render: (r) => r.pending.length
              ? <button className="s-btn sm warn" onClick={() => setModal({ kind: 'pending', row: r })}>{r.pending.length} pending</button> : '—' },
          { key: 'act', label: '', noExport: true, render: (r) => (
            <div className="row-actions">
              <button className="s-btn sm" onClick={() => setModal({ kind: 'stock', row: r })}>Stock</button>
              <button className="s-btn ghost sm" onClick={() => setModal({ kind: 'log', row: r })}>Log</button>
              <button className="s-btn ghost sm" onClick={() => setModal({ kind: 'flag', row: r })}>Flag</button>
            </div>) },
        ]} />
      </Panel>

      {modal?.kind === 'stock' && <StockModal row={modal.row} prizes={prizes} kit={defaultKit} role={data.role}
        onClose={(changed) => { setModal(null); if (changed) st.reload(); }} />}
      {modal?.kind === 'log' && <LogModal row={modal.row} prizes={prizes} onClose={() => setModal(null)} />}
      {modal?.kind === 'pending' && <PendingModal row={modal.row} onClose={(c) => { setModal(null); if (c) st.reload(); }} />}
      {modal?.kind === 'flag' && <FlagModal row={modal.row} onClose={() => setModal(null)} />}
    </div>
  );
}

function StockModal({ row, prizes, kit, role, onClose }) {
  const [type, setType] = useState('issue');
  const [qty, setQty] = useState({});
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  async function save() {
    setBusy(true); setErr('');
    try {
      const items = Object.entries(qty).filter(([, v]) => Number(v));
      if (!items.length) throw new Error('Enter at least one quantity');
      for (const [prize, v] of items) {
        await rpc('adjust_stock', { p_promoter: row.id, p_prize: prize, p_type: type, p_qty: Number(v), p_note: note || null, p_reference: null });
      }
      onClose(true);
    } catch (e) { setErr(friendly(e)); setBusy(false); }
  }

  return (
    <Modal title={`Prize stock — ${row.name}`} onClose={() => onClose(false)}>
      <div className="s-form">
        <Field label="Movement">
          <select value={type} onChange={(e) => setType(e.target.value)}>
            <option value="issue">Issue / replenish (+)</option>
            <option value="return">Returned by promoter (−)</option>
            <option value="damaged">Damaged (−)</option>
            <option value="missing">Missing (−)</option>
            {role === 'admin' && <option value="adjustment">Adjustment (± admin)</option>}
          </select>
        </Field>
        {type === 'issue' && Object.keys(kit).length > 0 && (
          <button className="s-btn ghost sm" onClick={() => setQty(kit)}>Fill one standard pool kit</button>
        )}
        <table className="mini">
          <thead><tr><th>Prize</th><th className="r">Current</th><th className="r">Quantity</th></tr></thead>
          <tbody>{prizes.map((p) => (
            <tr key={p.id}><td>{p.short_name}</td><td className="r">{row.stock[p.id]}</td>
              <td className="r"><input type="number" className="num" value={qty[p.id] ?? ''} onChange={(e) => setQty({ ...qty, [p.id]: e.target.value })} /></td></tr>
          ))}</tbody>
        </table>
        <Field label="Note / reference"><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Kit #12, returned at day end" /></Field>
        {err && <div className="s-err">{err}</div>}
        <div className="s-actions"><button className="s-btn ghost" onClick={() => onClose(false)}>Cancel</button>
          <button className="s-btn" disabled={busy} onClick={save}>{busy ? 'Saving…' : 'Save movement'}</button></div>
      </div>
    </Modal>
  );
}

function LogModal({ row, prizes, onClose }) {
  const log = useAsync(async () => {
    const { data, error } = await supabase.from('inventory_movements').select('*').eq('promoter_id', row.id).order('created_at', { ascending: false }).limit(300);
    if (error) throw error; return data;
  }, [row.id]);
  const pz = Object.fromEntries(prizes.map((p) => [p.id, p.short_name]));
  return (
    <Modal title={`Inventory movements — ${row.name}`} onClose={onClose} wide>
      {!log.data ? <Loading state={log} /> : (
        <DataTable rows={log.data.map((m) => ({ ...m, prize: pz[m.prize_id] }))} exportName={`inventory_${row.code}`} maxHeight="60vh" columns={[
          { key: 'created_at', label: 'Date/time', fmt: fmt.dt }, { key: 'prize', label: 'Prize' },
          { key: 'movement_type', label: 'Type' }, { key: 'qty', label: 'Qty', align: 'r' },
          { key: 'on_hand_after', label: 'Stock after', align: 'r' }, { key: 'reference', label: 'Ref' }, { key: 'note', label: 'Note' },
        ]} />
      )}
    </Modal>
  );
}

function PendingModal({ row, onClose }) {
  const [note, setNote] = useState('');
  const [err, setErr] = useState('');
  async function resolve(spin, action) {
    try { await rpc('resolve_spin', { p_spin_id: spin.id, p_action: action, p_note: note }); onClose(true); }
    catch (e) { setErr(friendly(e)); }
  }
  return (
    <Modal title={`Pending handovers — ${row.name}`} onClose={() => onClose(false)}>
      <p className="muted">Normally the promoter taps “Prize handed over”. Resolve here only after checking with them. Every resolution is audit-logged.</p>
      <Field label="Note (required)"><input value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      {row.pending.map((s) => (
        <div key={s.id} className="pending-row">
          <div><b>{s.prize_name}</b><br /><small>{s.spin_code} · {fmt.dt(s.created_at)}</small></div>
          <button className="s-btn sm" onClick={() => resolve(s, 'handed_over')}>Handed over</button>
          <button className="s-btn sm danger" onClick={() => resolve(s, 'not_redeemed')}>Not redeemed</button>
        </div>
      ))}
      {err && <div className="s-err">{err}</div>}
    </Modal>
  );
}

function FlagModal({ row, onClose }) {
  const [reason, setReason] = useState('');
  const [sev, setSev] = useState('medium');
  const [err, setErr] = useState('');
  async function save() {
    try { await rpc('raise_flag', { p_promoter: row.id, p_reason: reason, p_severity: sev }); onClose(); }
    catch (e) { setErr(friendly(e)); }
  }
  return (
    <Modal title={`Flag suspicious activity — ${row.name}`} onClose={onClose}>
      <div className="s-form">
        <Field label="Reason"><textarea rows="3" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        <Field label="Severity"><select value={sev} onChange={(e) => setSev(e.target.value)}><option>low</option><option>medium</option><option>high</option></select></Field>
        {err && <div className="s-err">{err}</div>}
        <div className="s-actions"><button className="s-btn" disabled={!reason.trim()} onClick={save}>Raise flag</button></div>
      </div>
    </Modal>
  );
}
