import React from 'react';
import { num } from '../lib/store.js';

export default function Home({ profile, home, ctx, online, onStart, onChangeOutlet, onChangeHierarchy, onRefresh }) {
  const t = home?.today || {};
  const stock = home?.stock || [];
  const low = stock.filter((s) => s.low);

  return (
    <main className="p-home">
      <div className="hello">Hi {profile.full_name.split(' ')[0]} 👋 <small>{home?.user?.promoter_code}</small></div>

      <section className="card today">
        <div className="card-h">TODAY <button className="link" onClick={onRefresh}>↻</button></div>
        <div className="stats kpi-4">
          <div><b>{num(t.sales ?? 0)}</b><span>Sales</span></div>
          <div><b>{num(t.spins ?? 0)}</b><span>Spins</span></div>
          <div><b>{num(t.prizes_given ?? 0)}</b><span>Prizes given</span></div>
          <div><b>{num(t.units ?? 0)}</b><span>Units sold</span></div>
        </div>
      </section>

      <section className="card outlet">
        <div className="card-h">CURRENT OUTLET</div>
        {ctx ? (
          <>
            <div className="outlet-name">{ctx.outletName}{ctx.outletArea ? ` – ${ctx.outletArea}` : ''}</div>
            <div className="outlet-meta">
              <div><span>TSE</span>{ctx.tseName}</div>
              <div><span>Territory</span>{ctx.territoryName}</div>
              <div><span>State</span>{ctx.stateName}</div>
              {ctx.campaign && <div><span>Campaign</span>{ctx.campaign.name}</div>}
            </div>
          </>
        ) : <div className="outlet-name muted">No outlet selected</div>}
        <div className="outlet-actions">
          <button className="btn-secondary" onClick={onChangeOutlet}>CHANGE OUTLET</button>
          <button className="btn-text" onClick={onChangeHierarchy}>Change Territory / TSE</button>
        </div>
      </section>

      {low.length > 0 && (
        <section className="alert-low">
          <b>LOW STOCK ALERT</b>
          {low.map((s) => <div key={s.prize_id}>{s.short_name} — only {s.on_hand} remaining</div>)}
        </section>
      )}

      <section className="card stock">
        <div className="card-h">MY PRIZE STOCK</div>
        <ul>
          {stock.map((s) => (
            <li key={s.prize_id} className={`${s.low ? 'low' : ''} tier-${s.tier}`}>
              <span>{s.short_name}</span><b>{s.on_hand - (s.reserved || 0)}</b>
            </li>
          ))}
          {!stock.length && <li className="muted">Stock not loaded yet</li>}
        </ul>
      </section>

      {!online && <p className="offline-note">You're offline. Outlet lists still work; a sale needs signal to record and spin.</p>}

      <div className="start-bar">
        <button className="btn-start" onClick={onStart}>
          <span className="start-ico">🎡</span> START NEW SALE
        </button>
      </div>
    </main>
  );
}
