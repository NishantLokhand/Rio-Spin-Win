import React, { useMemo } from 'react';
import { istToday } from '../lib/store.js';

export const defaultFilters = () => ({ date_from: istToday(), date_to: istToday() });

function daysAgo(n) {
  const d = new Date(Date.now() + 5.5 * 3600 * 1000 - n * 86400000);
  return d.toISOString().slice(0, 10);
}

/** One row of filters above the charts/tables. Cascading: State → Territory → TSE → Outlet */
export default function FilterBar({ data, filters, setFilters, show = 'all' }) {
  const f = filters;
  const set = (patch) => setFilters({ ...f, ...patch });
  const m = data.masters;
  const territories = useMemo(() => m.territories.filter((t) => !f.state_id || t.state_id === f.state_id), [m, f.state_id]);
  const tses = useMemo(() => m.tses.filter((t) => (!f.territory_id || t.territory_id === f.territory_id)
    && (!f.state_id || territories.some((x) => x.id === t.territory_id))), [m, f.territory_id, f.state_id, territories]);
  const outlets = useMemo(() => m.outlets.filter((o) => (!f.tse_id || o.tse_id === f.tse_id)
    && (f.tse_id || !f.territory_id || tses.some((t) => t.id === o.tse_id))), [m, f.tse_id, f.territory_id, tses]);
  const cities = useMemo(() => [...new Set(m.outlets.map((o) => o.city).filter(Boolean))].sort(), [m]);
  const distributors = useMemo(() => [...new Set((data.outletsFull || []).map((o) => o.distributor).filter(Boolean))].sort(), [data]);

  const preset = (from, to) => set({ date_from: from, date_to: to });
  const sel = (key, list, label, getLabel = (x) => x.name, reset = {}) => (
    <select value={f[key] || ''} onChange={(e) => set({ [key]: e.target.value || undefined, ...reset })} aria-label={label}>
      <option value="">{label}: All</option>
      {list.map((x) => <option key={x.id ?? x} value={x.id ?? x}>{getLabel(x)}</option>)}
    </select>
  );

  return (
    <div className="filterbar">
      <div className="fb-dates">
        <input type="date" value={f.date_from || ''} onChange={(e) => set({ date_from: e.target.value || undefined })} aria-label="From" />
        <span>→</span>
        <input type="date" value={f.date_to || ''} onChange={(e) => set({ date_to: e.target.value || undefined })} aria-label="To" />
        <div className="fb-presets">
          <button onClick={() => preset(istToday(), istToday())}>Today</button>
          <button onClick={() => preset(daysAgo(6), istToday())}>7D</button>
          <button onClick={() => preset(daysAgo(29), istToday())}>30D</button>
          <button onClick={() => preset(undefined, undefined)}>All</button>
        </div>
      </div>
      {show === 'all' && (
        <div className="fb-dims">
          {sel('campaign_id', data.campaigns, 'Campaign')}
          {sel('state_id', m.states, 'State', undefined, { territory_id: undefined, tse_id: undefined, outlet_id: undefined })}
          {sel('territory_id', territories, 'Territory', undefined, { tse_id: undefined, outlet_id: undefined })}
          {sel('tse_id', tses, 'TSE', undefined, { outlet_id: undefined })}
          {sel('city', cities, 'City', (x) => x)}
          {distributors.length > 0 && sel('distributor', distributors, 'Distributor', (x) => x)}
          {sel('outlet_id', outlets, 'Outlet')}
          {sel('promoter_id', data.promoters, 'Promoter', (x) => x.full_name)}
          {sel('product_id', m.products, 'SKU')}
          <button className="s-btn ghost sm" onClick={() => setFilters({ date_from: f.date_from, date_to: f.date_to })}>Clear</button>
        </div>
      )}
    </div>
  );
}
