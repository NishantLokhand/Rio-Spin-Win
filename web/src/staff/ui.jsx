import React, { useEffect, useMemo, useState, useCallback } from 'react';
import { exportCSV, exportXLSX } from '../lib/exporter.js';
import { inr, num } from '../lib/store.js';

export function useAsync(fn, deps) {
  const [s, set] = useState({ loading: true, data: null, error: null });
  const run = useCallback(async () => {
    set((x) => ({ ...x, loading: true, error: null }));
    try { set({ loading: false, data: await fn(), error: null }); }
    catch (e) { set({ loading: false, data: null, error: e }); }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => { run(); }, [run]);
  return { ...s, reload: run };
}

export const fmt = {
  inr: (v) => inr(v), inr2: (v) => inr(v, 2), num: (v) => num(v),
  date: (v) => (v ? new Date(v).toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' }) : '—'),
  dt: (v) => (v ? new Date(v).toLocaleString('en-IN', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : '—'),
  pct: (v) => (v == null ? '—' : `${Number(v).toFixed(1)}%`),
};

export function Kpi({ label, value, sub, tone }) {
  return (
    <div className={`kpi ${tone || ''}`}>
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{value}</div>
      {sub && <div className="kpi-sub">{sub}</div>}
    </div>
  );
}

export function Panel({ title, actions, children, className }) {
  return (
    <section className={`panel ${className || ''}`}>
      {(title || actions) && <div className="panel-h"><h3>{title}</h3><div className="panel-actions">{actions}</div></div>}
      {children}
    </section>
  );
}

export function Loading({ state }) {
  if (state?.error) return <div className="s-err">{state.error.message}</div>;
  return <div className="s-loading">Loading…</div>;
}

/**
 * columns: [{ key, label, fmt?: fn, align?: 'r', render?: (row) => node }]
 */
export function DataTable({ rows, columns, exportName, onRowClick, empty = 'No data', maxHeight, footer }) {
  const [sort, setSort] = useState(null);
  const sorted = useMemo(() => {
    if (!sort || !rows) return rows || [];
    const { key, dir } = sort;
    return [...rows].sort((a, b) => {
      const x = a[key]; const y = b[key];
      if (x == null) return 1; if (y == null) return -1;
      const nx = Number(x); const ny = Number(y);
      const c = !isNaN(nx) && !isNaN(ny) && x !== '' && y !== '' ? nx - ny : String(x).localeCompare(String(y));
      return dir === 'asc' ? c : -c;
    });
  }, [rows, sort]);
  const exp = columns.filter((c) => !c.noExport);
  return (
    <div className="dt">
      {exportName && rows?.length > 0 && (
        <div className="dt-tools">
          <span>{rows.length} rows</span>
          <button className="s-btn ghost sm" onClick={() => exportCSV(rows, exp, exportName)}>CSV</button>
          <button className="s-btn ghost sm" onClick={() => exportXLSX(rows, exp, exportName)}>Excel</button>
        </div>
      )}
      <div className="dt-scroll" style={maxHeight ? { maxHeight } : null}>
        <table>
          <thead>
            <tr>{columns.map((c) => (
              <th key={c.key} className={c.align === 'r' ? 'r' : ''}
                  onClick={() => !c.render && setSort((s) => ({ key: c.key, dir: s?.key === c.key && s.dir === 'desc' ? 'asc' : 'desc' }))}>
                {c.label}{sort?.key === c.key ? (sort.dir === 'desc' ? ' ▾' : ' ▴') : ''}
              </th>))}</tr>
          </thead>
          <tbody>
            {sorted.map((r, i) => (
              <tr key={r.id || r.key || i} onClick={onRowClick ? () => onRowClick(r) : undefined} className={onRowClick ? 'click' : ''}>
                {columns.map((c) => (
                  <td key={c.key} className={c.align === 'r' ? 'r' : ''}>
                    {c.render ? c.render(r) : c.fmt ? c.fmt(r[c.key], r) : r[c.key] ?? '—'}
                  </td>))}
              </tr>
            ))}
            {!sorted.length && <tr><td colSpan={columns.length} className="dt-empty">{empty}</td></tr>}
          </tbody>
          {footer}
        </table>
      </div>
    </div>
  );
}

export function Modal({ title, onClose, children, wide }) {
  return (
    <div className="s-modal" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`s-modal-card ${wide ? 'wide' : ''}`}>
        <div className="s-modal-h"><h3>{title}</h3><button className="s-x" onClick={onClose}>✕</button></div>
        {children}
      </div>
    </div>
  );
}

export function Field({ label, children, hint }) {
  return <label className="s-field"><span>{label}</span>{children}{hint && <small>{hint}</small>}</label>;
}

/** Single-series horizontal bars (one hue; value labels in ink, not series colour) */
export function BarList({ rows, valueKey, labelKey, format = (v) => v, sub }) {
  const max = Math.max(1, ...rows.map((r) => Number(r[valueKey]) || 0));
  return (
    <div className="barlist" role="table">
      {rows.map((r, i) => (
        <div className="bar-row" key={i} role="row" title={`${r[labelKey]}: ${format(r[valueKey])}${sub ? ' · ' + sub(r) : ''}`}>
          <div className="bar-label" role="cell">{r[labelKey]}</div>
          <div className="bar-track"><div className="bar-fill" style={{ width: `${(Number(r[valueKey]) || 0) / max * 100}%` }} /></div>
          <div className="bar-val" role="cell">{format(r[valueKey])}{sub && <small>{sub(r)}</small>}</div>
        </div>
      ))}
    </div>
  );
}

/** Single-series vertical bars over time with hover tooltip */
export function ColumnChart({ rows, xKey, yKey, format = (v) => v, xFormat = (v) => v, height = 160 }) {
  const [hover, setHover] = useState(null);
  const max = Math.max(1, ...rows.map((r) => Number(r[yKey]) || 0));
  return (
    <div className="colchart" style={{ height }}>
      <div className="col-grid"><span>{format(max)}</span><span>{format(Math.round(max / 2))}</span><span>0</span></div>
      <div className="col-bars" onMouseLeave={() => setHover(null)}>
        {rows.map((r, i) => (
          <div key={i} className="col-hit" onMouseEnter={() => setHover(i)} onTouchStart={() => setHover(i)}>
            <div className={`col ${hover === i ? 'on' : ''}`} style={{ height: `${(Number(r[yKey]) || 0) / max * 100}%` }} />
            {hover === i && <div className="col-tip"><b>{format(r[yKey])}</b><span>{xFormat(r[xKey])}</span></div>}
          </div>
        ))}
      </div>
      <div className="col-x"><span>{rows[0] ? xFormat(rows[0][xKey]) : ''}</span><span>{rows.length > 1 ? xFormat(rows[rows.length - 1][xKey]) : ''}</span></div>
    </div>
  );
}

export function Tabs({ tabs, value, onChange }) {
  return (
    <div className="s-tabs">
      {tabs.map((t) => <button key={t.key} className={value === t.key ? 'on' : ''} onClick={() => onChange(t.key)}>{t.label}</button>)}
    </div>
  );
}

export function Badge({ tone = 'grey', children }) { return <span className={`badge ${tone}`}>{children}</span>; }
