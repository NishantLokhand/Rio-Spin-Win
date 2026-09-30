import React, { useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { selectAll, friendly } from '../lib/api.js';
import { useAsync, Panel, Loading, DataTable, Modal, Field, Badge, fmt } from './ui.jsx';

const VALIDATIONS = [['invoice_no', 'Invoice number'], ['receipt_no', 'Retail receipt number'], ['qr_code', 'QR code'], ['barcode', 'Product barcode'], ['receipt_photo', 'Receipt photograph'], ['retailer_confirmation', 'Retailer confirmation']];
const FLAG_RULES = [['min_seconds_between_spins', 'Min seconds between spins'], ['max_spins_per_day', 'Max spins / promoter / day'],
  ['high_value_cost', 'High-value prize = cost ≥ ₹'], ['max_high_value_per_day', 'Max high-value wins / day'],
  ['max_cancelled_per_day', 'Max cancelled sales / day'], ['max_outlet_requests_per_day', 'Max outlet requests / day'],
  ['slow_handover_minutes', 'Slow handover after (min)'], ['stale_pending_minutes', 'Pending handover alert after (min)']];

const blank = { code: '', name: '', status: 'draft', start_date: '', end_date: '', target_cost_per_spin: 10, total_budget: '', daily_budget: '',
  enforce_budget: false, pool_scope: 'campaign', draw_strategy: 'controlled_pool', oos_mode: 'defer', config_change_mode: 'next_pool',
  track_inventory: true, spins_per_sale: 1, max_quantity_per_sale: 24, validation_rules: {}, capture_consumer: false, sound_default: true,
  work_start: '09:00', work_end: '22:30', flag_rules: { min_seconds_between_spins: 20, max_spins_per_day: 250, high_value_cost: 100, max_high_value_per_day: 3,
    max_cancelled_per_day: 5, max_outlet_requests_per_day: 3, slow_handover_minutes: 20, stale_pending_minutes: 30 } };

export default function Campaigns({ data, reloadData }) {
  const [edit, setEdit] = useState(null);
  return (
    <div className="s-page">
      <Panel title="Campaigns" actions={<button className="s-btn sm" onClick={() => setEdit({ ...blank })}>+ New campaign</button>}>
        <DataTable rows={data.campaigns} columns={[
          { key: 'name', label: 'Campaign', render: (r) => <><b>{r.name}</b><br /><small className="muted">{r.code}</small></> },
          { key: 'status', label: 'Status', render: (r) => <Badge tone={{ active: 'green', paused: 'amber', closed: 'grey', draft: 'grey' }[r.status]}>{r.status}</Badge> },
          { key: 'start_date', label: 'Start', fmt: fmt.date }, { key: 'end_date', label: 'End', fmt: fmt.date },
          { key: 'total_budget', label: 'Budget', align: 'r', fmt: fmt.inr }, { key: 'target_cost_per_spin', label: 'Target/spin', align: 'r', fmt: fmt.inr2 },
          { key: 'rule', label: 'Spin rule', render: (r) => `cumulative allocation · per ${r.pool_scope} · OOS ${r.oos_mode}` },
          { key: 'e', label: '', render: (r) => <button className="s-btn sm" onClick={() => setEdit(r)}>Edit</button> },
        ]} />
      </Panel>
      {edit && <CampaignModal c={edit} data={data} onClose={(ch) => { setEdit(null); if (ch) reloadData(); }} />}
    </div>
  );
}

function CampaignModal({ c: initial, data, onClose }) {
  const [c, setC] = useState({ ...blank, ...initial, flag_rules: { ...blank.flag_rules, ...(initial.flag_rules || {}) } });
  const isNew = !initial.id;
  const links = useAsync(async () => {
    if (isNew) return { states: [], terr: [], products: data.masters.products.map((p) => p.id), promoters: [] };
    const [states, terr, products, promoters] = await Promise.all([
      selectAll('campaign_states', '*', (q) => q.eq('campaign_id', initial.id)),
      selectAll('campaign_territory_budgets', '*', (q) => q.eq('campaign_id', initial.id)),
      selectAll('campaign_products', '*', (q) => q.eq('campaign_id', initial.id)),
      selectAll('campaign_promoters', '*', (q) => q.eq('campaign_id', initial.id)),
    ]);
    return { states, terr, products: products.map((p) => p.product_id), promoters: promoters.map((p) => p.promoter_id) };
  }, [initial.id]);
  const [L, setL] = useState(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  if (links.data && !L) setL(links.data);
  const set = (k, v) => setC({ ...c, [k]: v });
  const inp = (k, type = 'text') => <input type={type} value={c[k] ?? ''} onChange={(e) => set(k, e.target.value)} />;

  async function save() {
    setBusy(true); setErr('');
    try {
      const row = { code: c.code, name: c.name, status: c.status, start_date: c.start_date || null, end_date: c.end_date || null,
        target_cost_per_spin: Number(c.target_cost_per_spin), total_budget: c.total_budget === '' ? null : Number(c.total_budget),
        daily_budget: c.daily_budget === '' || c.daily_budget == null ? null : Number(c.daily_budget), enforce_budget: c.enforce_budget,
        pool_scope: c.pool_scope, draw_strategy: 'controlled_pool', oos_mode: c.oos_mode, config_change_mode: c.config_change_mode,
        track_inventory: c.track_inventory, spins_per_sale: Number(c.spins_per_sale), max_quantity_per_sale: Number(c.max_quantity_per_sale),
        validation_rules: c.validation_rules, capture_consumer: c.capture_consumer, sound_default: c.sound_default,
        work_start: c.work_start, work_end: c.work_end, flag_rules: Object.fromEntries(Object.entries(c.flag_rules).map(([k, v]) => [k, Number(v)])) };
      let id = initial.id;
      if (isNew) {
        const { data: ins, error } = await supabase.from('campaigns').insert(row).select('id').single();
        if (error) throw error; id = ins.id;
      } else {
        const { error } = await supabase.from('campaigns').update(row).eq('id', id);
        if (error) throw error;
      }
      // replace link tables
      for (const t of ['campaign_states', 'campaign_territory_budgets', 'campaign_products', 'campaign_promoters']) {
        const { error } = await supabase.from(t).delete().eq('campaign_id', id);
        if (error) throw error;
      }
      const ins = async (t, rows) => { if (rows.length) { const { error } = await supabase.from(t).insert(rows); if (error) throw error; } };
      await ins('campaign_states', L.states.map((s) => ({ campaign_id: id, state_id: s.state_id, budget: s.budget === '' || s.budget == null ? null : Number(s.budget) })));
      await ins('campaign_territory_budgets', L.terr.filter((t) => t.budget !== '' && t.budget != null).map((t) => ({ campaign_id: id, territory_id: t.territory_id, budget: Number(t.budget) })));
      await ins('campaign_products', L.products.map((p, i) => ({ campaign_id: id, product_id: p, sort_order: i })));
      await ins('campaign_promoters', L.promoters.map((p) => ({ campaign_id: id, promoter_id: p })));
      onClose(true);
    } catch (e) { setErr(friendly(e)); setBusy(false); }
  }

  const toggle = (arr, v) => (arr.includes(v) ? arr.filter((x) => x !== v) : [...arr, v]);

  return (
    <Modal title={isNew ? 'New campaign' : `Edit — ${initial.name}`} onClose={() => onClose(false)} wide>
      {!L ? <Loading state={links} /> : (
        <div className="s-form">
          <div className="s-grid3">
            <Field label="Code">{inp('code')}</Field>
            <Field label="Name">{inp('name')}</Field>
            <Field label="Status"><select value={c.status} onChange={(e) => set('status', e.target.value)}>{['draft', 'active', 'paused', 'closed'].map((s) => <option key={s}>{s}</option>)}</select></Field>
            <Field label="Start date">{inp('start_date', 'date')}</Field>
            <Field label="End date">{inp('end_date', 'date')}</Field>
            <Field label="Target cost / spin (₹)">{inp('target_cost_per_spin', 'number')}</Field>
            <Field label="Total budget (₹)">{inp('total_budget', 'number')}</Field>
            <Field label="Daily budget (₹)">{inp('daily_budget', 'number')}</Field>
            <label className="check"><input type="checkbox" checked={c.enforce_budget} onChange={(e) => set('enforce_budget', e.target.checked)} /> Stop sales when a budget is used up</label>
          </div>

          <h4>Spin rule (cumulative allocation applies to all new spins)</h4>
          <div className="s-grid3">
            <Field label="Draw strategy"><input value="Controlled cumulative random allocation" disabled /></Field>
            <Field label="Cumulative distribution scope"><select value={c.pool_scope} onChange={(e) => set('pool_scope', e.target.value)}>
              {['promoter', 'outlet', 'territory', 'state', 'campaign'].map((s) => <option key={s}>{s}</option>)}</select></Field>
            <Field label="Prize shortage policy"><select value={c.oos_mode} onChange={(e) => set('oos_mode', e.target.value)}>
              <option value="defer">Continue with available stock and track the deficit</option>
              <option value="block">Pause spins while any configured prize is unavailable</option>
              {c.oos_mode === 'substitute' && <option value="substitute">Legacy setting (treated as continue with available stock)</option>}
            </select></Field>
            <Field label="Spins per sale">{inp('spins_per_sale', 'number')}</Field>
            <Field label="Max quantity per sale">{inp('max_quantity_per_sale', 'number')}</Field>
            <label className="check"><input type="checkbox" checked={c.track_inventory} onChange={(e) => set('track_inventory', e.target.checked)} /> Enforce promoter prize inventory</label>
            <label className="check"><input type="checkbox" checked={c.sound_default} onChange={(e) => set('sound_default', e.target.checked)} /> Sound on by default</label>
            <label className="check"><input type="checkbox" checked={c.capture_consumer} onChange={(e) => set('capture_consumer', e.target.checked)} /> Consumer data capture (future)</label>
          </div>

          <h4>Optional sale validation</h4>
          <div className="s-grid3">
            {VALIDATIONS.map(([k, label]) => (
              <Field key={k} label={label}><select value={c.validation_rules[k] || 'off'} onChange={(e) => {
                const v = { ...c.validation_rules }; if (e.target.value === 'off') delete v[k]; else v[k] = e.target.value; set('validation_rules', v);
              }}><option value="off">Off</option><option value="optional">Optional</option><option value="required">Required</option></select></Field>
            ))}
          </div>

          <h4>Fraud flag rules</h4>
          <div className="s-grid4">
            <Field label="Working hours start">{inp('work_start', 'time')}</Field>
            <Field label="Working hours end">{inp('work_end', 'time')}</Field>
            {FLAG_RULES.map(([k, label]) => (
              <Field key={k} label={label}><input type="number" value={c.flag_rules[k] ?? ''} onChange={(e) => set('flag_rules', { ...c.flag_rules, [k]: e.target.value })} /></Field>
            ))}
          </div>

          <h4>States covered &amp; state budgets</h4>
          <div className="s-grid3">
            {data.masters.states.map((s) => {
              const row = L.states.find((x) => x.state_id === s.id);
              return (
                <div key={s.id} className="linkrow">
                  <label className="check"><input type="checkbox" checked={!!row} onChange={() => setL({ ...L, states: row ? L.states.filter((x) => x.state_id !== s.id) : [...L.states, { state_id: s.id, budget: '' }] })} /> {s.name}</label>
                  {row && <input type="number" placeholder="State budget ₹" value={row.budget ?? ''} onChange={(e) => setL({ ...L, states: L.states.map((x) => (x.state_id === s.id ? { ...x, budget: e.target.value } : x)) })} />}
                </div>);
            })}
          </div>
          <details><summary>Territory budgets (optional)</summary>
            <div className="s-grid3">
              {data.masters.territories.filter((t) => L.states.some((s) => s.state_id === t.state_id)).map((t) => {
                const row = L.terr.find((x) => x.territory_id === t.id);
                return <Field key={t.id} label={t.name}><input type="number" value={row?.budget ?? ''} onChange={(e) => setL({ ...L, terr: [...L.terr.filter((x) => x.territory_id !== t.id), { territory_id: t.id, budget: e.target.value }] })} /></Field>;
              })}
            </div>
          </details>

          <h4>Products (SKUs) in this campaign</h4>
          <div className="chips">
            {data.masters.products.map((p) => <button key={p.id} className={`chip ${L.products.includes(p.id) ? 'on' : ''}`} onClick={() => setL({ ...L, products: toggle(L.products, p.id) })}>{p.name}</button>)}
          </div>
          <h4>Promoters <small className="muted">(none selected = all promoters in covered states)</small></h4>
          <div className="chips">
            {data.promoters.map((p) => <button key={p.id} className={`chip ${L.promoters.includes(p.id) ? 'on' : ''}`} onClick={() => setL({ ...L, promoters: toggle(L.promoters, p.id) })}>{p.full_name}</button>)}
          </div>

          {err && <div className="s-err">{err}</div>}
          <div className="s-actions"><button className="s-btn ghost" onClick={() => onClose(false)}>Cancel</button>
            <button className="s-btn" disabled={busy || !c.code || !c.name} onClick={save}>{busy ? 'Saving…' : 'Save campaign'}</button></div>
          {isNew && <div className="s-note">After saving, set its prize structure in <b>Prize Structure</b>.</div>}
        </div>
      )}
    </Modal>
  );
}
