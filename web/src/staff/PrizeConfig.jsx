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
    const { data: rows, error } = await supabase.from('prize_configs')
      .select('*, prize_config_items(prize_id,quantity,unit_cost,percentage)')
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

    const defaultDistribution = {
      SNACK5: { pct: 76.0, qty: 152, cost: 5 },
      SNACK10: { pct: 17.0, qty: 34, cost: 10 },
      RIODARE: { pct: 5.0, qty: 10, cost: 40 },
      SHADES: { pct: 1.5, qty: 3, cost: 100 },
      SPEAKER: { pct: 0.5, qty: 1, cost: 200 },
    };

    const base = {};
    prizes.data.forEach((p) => {
      const def = defaultDistribution[p.code] || { pct: 0, qty: 0, cost: Number(p.default_cost) };
      base[p.id] = { quantity: def.qty, percentage: def.pct, unit_cost: def.cost };
    });

    if (active) {
      setPoolSize(active.pool_size || 200);
      active.prize_config_items.forEach((i) => {
        const pct = i.percentage != null && Number(i.percentage) > 0
          ? Number(i.percentage)
          : Number((Number(i.quantity) / (active.pool_size || 200)) * 100);
        base[i.prize_id] = { quantity: i.quantity, percentage: pct, unit_cost: Number(i.unit_cost) };
      });
    }
    setItems(base); setOverride(false); setMsg(null);
  }, [hist.data, prizes.data, stateId]);

  if (!prizes.data || !hist.data) return <div className="s-page"><Loading state={prizes.error ? prizes : hist} /></div>;

  const rows = prizes.data.map((p) => ({
    ...p,
    ...(items[p.id] || { quantity: 0, percentage: 0, unit_cost: Number(p.default_cost) }),
  }));

  const totalPct = rows.reduce((a, r) => a + Number(r.percentage || 0), 0);
  const totalRefQty = rows.reduce((a, r) => a + Number(r.quantity || 0), 0);
  const avg = rows.reduce((a, r) => a + (Number(r.percentage || 0) / 100) * Number(r.unit_cost || 0), 0);
  const totalRefCost = rows.reduce((a, r) => a + Number(r.quantity || 0) * Number(r.unit_cost || 0), 0);

  const target = Number(c?.target_cost_per_spin || 10);
  const over = avg > target + 1e-4;
  const mismatch = Math.abs(totalPct - 100.0) > 0.05;
  const canOverride = data.profile.can_override_cost_target;

  const updatePct = (id, newPct) => {
    const pVal = Number(newPct) || 0;
    const qVal = Math.round((pVal / 100) * poolSize);
    setItems({ ...items, [id]: { ...items[id], percentage: newPct, quantity: qVal } });
  };

  const updateQty = (id, newQty) => {
    const qVal = Number(newQty) || 0;
    const pVal = poolSize > 0 ? (qVal / poolSize) * 100 : 0;
    setItems({ ...items, [id]: { ...items[id], quantity: newQty, percentage: pVal } });
  };

  const updateCost = (id, newCost) => {
    setItems({ ...items, [id]: { ...items[id], unit_cost: newCost } });
  };

  async function save() {
    setBusy(true); setMsg(null);
    try {
      const res = await rpc('save_prize_config', {
        p_campaign: campaign,
        p_state: stateId || null,
        p_pool_size: Number(poolSize) || 200,
        p_items: rows.map((r) => ({
          prize_id: r.id,
          percentage: Number(r.percentage) || 0,
          quantity: Number(r.quantity) || 0,
          unit_cost: Number(r.unit_cost) || 0,
        })),
        p_override: override,
        p_notes: notes || null,
      });
      setMsg({ ok: true, text: `Saved as version ${res.version}. Continuous cumulative allocation will maintain this distribution across all campaign spins.` });
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

      <Panel title={`Prize Distribution & Target Percentages — ${stateName(stateId)}`}>
        <div className="s-form">
          <p className="muted" style={{ margin: '0 0 12px' }}>
            The system continuously allocates prizes using <b>Controlled Cumulative Random Allocation</b> across any spin volume (200, 500, 1000+ spins).
            Percentages must sum to exactly 100%. Reference quantities correspond to the 200-spin benchmark.
          </p>
          <table className="mini cfg">
            <thead>
              <tr>
                <th>Prize</th>
                <th className="r">Unit Cost (₹)</th>
                <th className="r">Target %</th>
                <th className="r">Ref Qty / 200 Spins</th>
                <th className="r">Expected Cost / Spin</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const expCost = (Number(r.percentage || 0) / 100) * Number(r.unit_cost || 0);
                return (
                  <tr key={r.id}>
                    <td><b>{r.name}</b> <small className="muted">{r.tier}</small></td>
                    <td className="r">
                      <input type="number" min="0" step="0.5" className="num" value={r.unit_cost} onChange={(e) => updateCost(r.id, e.target.value)} />
                    </td>
                    <td className="r">
                      <input type="number" min="0" max="100" step="0.1" className="num" value={r.percentage} onChange={(e) => updatePct(r.id, e.target.value)} /> %
                    </td>
                    <td className="r">
                      <input type="number" min="0" className="num" value={r.quantity} onChange={(e) => updateQty(r.id, e.target.value)} />
                    </td>
                    <td className="r">{fmt.inr2(expCost)}</td>
                  </tr>
                );
              })}
            </tbody>
            <tfoot>
              <tr>
                <td><b>Total</b></td>
                <td />
                <td className={`r ${mismatch ? 'txt-bad' : ''}`}><b>{totalPct.toFixed(1)}%</b> / 100%</td>
                <td className="r"><b>{totalRefQty}</b> / {poolSize}</td>
                <td className="r"><b>{fmt.inr2(avg)}</b></td>
              </tr>
            </tfoot>
          </table>

          <div className={`economics ${over ? 'bad' : 'good'}`}>
            <div>
              Expected Giveaway Formula: <b>∑ (Target % × Unit Cost)</b> = <b>{fmt.inr(totalRefCost)} ÷ {poolSize}</b>
            </div>
            <div className="econ-big">Expected Average Cost Per Spin: {fmt.inr2(avg)}</div>
            {over && <div className="econ-warn">WARNING: This prize configuration exceeds the {fmt.inr(target)} campaign target.</div>}
          </div>
          {mismatch && <div className="s-err">Target percentages add up to {totalPct.toFixed(1)}%; they must equal 100.0%.</div>}
          {over && (canOverride
            ? <label className="check"><input type="checkbox" checked={override} onChange={(e) => setOverride(e.target.checked)} /> I am authorised and override the cost target</label>
            : <div className="s-note">You are not authorised to override the cost target.</div>)}
          <Field label="Change note"><input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Reason for updating prize distribution" /></Field>
          {msg && <div className={msg.ok ? 's-ok' : 's-err'}>{msg.text}</div>}
          <div className="s-actions"><button className="s-btn" disabled={busy || mismatch || (over && !override)} onClick={save}>Save as new version</button></div>
        </div>
      </Panel>

      <Panel title="Version history">
        <DataTable rows={hist.data.map((h) => ({ ...h, scope: stateName(h.state_id) }))} columns={[
          { key: 'version', label: 'Version', align: 'r' },
          { key: 'scope', label: 'Applies to' },
          { key: 'avg_cost', label: 'Expected Cost/Spin', align: 'r', fmt: fmt.inr2 },
          { key: 'exceeds_target', label: 'Override', fmt: (v) => (v ? 'Yes' : '') },
          { key: 'is_active', label: 'Active', fmt: (v) => (v ? '● active' : '') },
          { key: 'created_at', label: 'Saved', fmt: fmt.dt },
          { key: 'notes', label: 'Note' },
        ]} />
      </Panel>
    </div>
  );
}
