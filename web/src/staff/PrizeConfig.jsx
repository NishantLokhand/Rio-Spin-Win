import React, { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, friendly, selectAll } from '../lib/api.js';
import { useAsync, Panel, Loading, DataTable, Field, fmt } from './ui.jsx';

export default function PrizeConfig({ data }) {
  const [campaign, setCampaign] = useState(data.campaigns[0]?.id);
  const [stateId, setStateId] = useState('');
  const c = data.campaigns.find((x) => x.id === campaign);
  const prizes = useAsync(() => selectAll('prizes', '*', (q) => q.eq('is_active', true).order('sort_order')), []);
  const hist = useAsync(async () => {
    const { data: rows, error } = await supabase.from('prize_configs').select('*, prize_config_items(prize_id,quantity,unit_cost)')
      .eq('campaign_id', campaign).order('version', { ascending: false });
    if (error) throw error; return rows;
  }, [campaign]);

  const [poolSize, setPoolSize] = useState(200);
  const [items, setItems] = useState({});
  const [override, setOverride] = useState(false);
  const [notes, setNotes] = useState('');
  const [msg, setMsg] = useState(null);
  const [busy, setBusy] = useState(false);

  // load the active config for campaign/state as starting point
  useEffect(() => {
    if (!hist.data || !prizes.data) return;
    const active = hist.data.find((h) => h.is_active && (h.state_id || '') === stateId)
      || hist.data.find((h) => h.is_active && !h.state_id);
    const base = Object.fromEntries(prizes.data.map((p) => [p.id, { quantity: 0, unit_cost: Number(p.default_cost) }]));
    if (active) {
      setPoolSize(active.pool_size);
      active.prize_config_items.forEach((i) => { base[i.prize_id] = { quantity: i.quantity, unit_cost: Number(i.unit_cost) }; });
    }
    setItems(base); setOverride(false); setMsg(null);
  }, [hist.data, prizes.data, stateId]);

  if (!prizes.data || !hist.data) return <div className="s-page"><Loading state={prizes.error ? prizes : hist} /></div>;

  const rows = prizes.data.map((p) => ({ ...p, ...(items[p.id] || { quantity: 0, unit_cost: 0 }) }));
  const totalQty = rows.reduce((a, r) => a + Number(r.quantity || 0), 0);
  const totalCost = rows.reduce((a, r) => a + Number(r.quantity || 0) * Number(r.unit_cost || 0), 0);
  const avg = poolSize > 0 ? totalCost / poolSize : 0;
  const target = Number(c?.target_cost_per_spin || 10);
  const over = avg > target + 1e-9;
  const mismatch = totalQty !== Number(poolSize);
  const canOverride = data.profile.can_override_cost_target;
  const set = (id, k, v) => setItems({ ...items, [id]: { ...items[id], [k]: v } });

  async function save() {
    setBusy(true); setMsg(null);
    try {
      const res = await rpc('save_prize_config', {
        p_campaign: campaign, p_state: stateId || null, p_pool_size: Number(poolSize),
        p_items: rows.filter((r) => Number(r.quantity) > 0).map((r) => ({ prize_id: r.id, quantity: Number(r.quantity), unit_cost: Number(r.unit_cost) })),
        p_override: override, p_notes: notes || null,
      });
      setMsg({ ok: true, text: `Saved as version ${res.version}. New pools will use it${c?.config_change_mode === 'regenerate_now' ? ' immediately (open pools are voided and regenerated).' : ' (open pools finish on the previous structure).'}` });
      setNotes(''); hist.reload();
    } catch (e) { setMsg({ ok: false, text: friendly(e) }); } finally { setBusy(false); }
  }

  const stateName = (id) => data.masters.states.find((s) => s.id === id)?.name || 'Campaign default';

  return (
    <div className="s-page">
      <div className="filterbar"><div className="fb-dims">
        <select value={campaign} onChange={(e) => setCampaign(e.target.value)}>
          {data.campaigns.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
        </select>
        <select value={stateId} onChange={(e) => setStateId(e.target.value)}>
          <option value="">Campaign default (all states)</option>
          {data.masters.states.map((s) => <option key={s.id} value={s.id}>State-specific: {s.name}</option>)}
        </select>
      </div></div>

      <Panel title={`Prize structure — ${stateName(stateId)}`}>
        <div className="s-form">
          <Field label="Pool size (spins per pool)"><input type="number" min="1" value={poolSize} onChange={(e) => setPoolSize(e.target.value)} className="num" /></Field>
          <table className="mini cfg">
            <thead><tr><th>Prize</th><th className="r">Cost (₹)</th><th className="r">Quantity per pool</th><th className="r">Line cost</th><th className="r">Mix %</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id}>
                <td><b>{r.name}</b> <small className="muted">{r.tier}</small></td>
                <td className="r"><input type="number" min="0" step="0.5" className="num" value={r.unit_cost} onChange={(e) => set(r.id, 'unit_cost', e.target.value)} /></td>
                <td className="r"><input type="number" min="0" className="num" value={r.quantity} onChange={(e) => set(r.id, 'quantity', e.target.value)} /></td>
                <td className="r">{fmt.inr(Number(r.quantity) * Number(r.unit_cost))}</td>
                <td className="r">{poolSize > 0 ? fmt.pct((Number(r.quantity) / poolSize) * 100) : '—'}</td>
              </tr>))}</tbody>
            <tfoot><tr><td>Total</td><td /><td className={`r ${mismatch ? 'txt-bad' : ''}`}><b>{totalQty}</b> / {poolSize}</td><td className="r"><b>{fmt.inr(totalCost)}</b></td><td /></tr></tfoot>
          </table>

          <div className={`economics ${over ? 'bad' : 'good'}`}>
            <div>Total Prize Cost ÷ Number of Spins = <b>{fmt.inr(totalCost)} ÷ {poolSize}</b></div>
            <div className="econ-big">Average Cost Per Spin: {fmt.inr2(avg)}</div>
            {over && <div className="econ-warn">WARNING: This prize configuration exceeds the {fmt.inr(target)} campaign target.</div>}
          </div>
          {mismatch && <div className="s-err">Quantities add up to {totalQty}; they must equal the pool size ({poolSize}).</div>}
          {over && (canOverride
            ? <label className="check"><input type="checkbox" checked={override} onChange={(e) => setOverride(e.target.checked)} /> I am authorised and override the cost target</label>
            : <div className="s-note">You are not authorised to override the cost target.</div>)}
          <Field label="Change note"><input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Why is the structure changing?" /></Field>
          {msg && <div className={msg.ok ? 's-ok' : 's-err'}>{msg.text}</div>}
          <div className="s-actions"><button className="s-btn" disabled={busy || mismatch || (over && !override)} onClick={save}>Save as new version</button></div>
        </div>
      </Panel>

      <Panel title="Version history">
        <DataTable rows={hist.data.map((h) => ({ ...h, scope: stateName(h.state_id) }))} columns={[
          { key: 'version', label: 'Version', align: 'r' }, { key: 'scope', label: 'Applies to' },
          { key: 'pool_size', label: 'Pool size', align: 'r' }, { key: 'total_cost', label: 'Total cost', align: 'r', fmt: fmt.inr },
          { key: 'avg_cost', label: 'Avg/spin', align: 'r', fmt: fmt.inr2 },
          { key: 'exceeds_target', label: 'Override', fmt: (v) => (v ? 'Yes' : '') },
          { key: 'is_active', label: 'Active', fmt: (v) => (v ? '● active' : '') },
          { key: 'created_at', label: 'Saved', fmt: fmt.dt }, { key: 'notes', label: 'Note' },
        ]} />
      </Panel>
    </div>
  );
}
