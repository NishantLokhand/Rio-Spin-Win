import React, { useMemo, useState } from 'react';
import { getRecent } from '../lib/session.js';

export default function OutletPicker({ masters, ctx, uid, full, onPick, onCancel, onNotListed, onReload }) {
  const [step, setStep] = useState(full || !ctx ? 'state' : 'outlet');
  const [sel, setSel] = useState(() => (full || !ctx ? {} : { stateId: ctx.stateId, territoryId: ctx.territoryId, tseId: ctx.tseId }));
  const [q, setQ] = useState('');

  const state = masters.states.find((s) => s.id === sel.stateId);
  const terr = masters.territories.find((t) => t.id === sel.territoryId);
  const tse = masters.tses.find((t) => t.id === sel.tseId);

  const territories = useMemo(() => masters.territories.filter((t) => t.state_id === sel.stateId), [masters, sel.stateId]);
  const tses = useMemo(() => masters.tses.filter((t) => t.territory_id === sel.territoryId), [masters, sel.territoryId]);
  const outlets = useMemo(() => masters.outlets.filter((o) => o.tse_id === sel.tseId), [masters, sel.tseId]);

  const recent = useMemo(() => {
    const ids = getRecent(uid);
    return ids.map((id) => outlets.find((o) => o.id === id)).filter(Boolean).slice(0, 4);
  }, [uid, outlets]);

  const filtered = useMemo(() => {
    const s = q.trim().toLowerCase();
    if (!s) return outlets;
    return outlets.filter((o) => [o.name, o.outlet_code, o.area, o.city].some((v) => (v || '').toLowerCase().includes(s)));
  }, [q, outlets]);

  const Title = { state: 'SELECT STATE', territory: 'SELECT TERRITORY', tse: 'SELECT MAPPED TSE', outlet: 'SELECT OUTLET' }[step];

  const back = () => {
    if (step === 'territory') setStep('state');
    else if (step === 'tse') setStep('territory');
    else if (step === 'outlet' && (full || !ctx)) setStep('tse');
    else onCancel && onCancel();
  };

  return (
    <main className="picker">
      <div className="picker-top">
        {(step !== 'state' || onCancel) && <button className="back" onClick={step === 'state' ? onCancel : back}>‹</button>}
        <h2>{Title}</h2>
        {step === 'state' && <button className="link small" onClick={onReload}>↻ Refresh list</button>}
      </div>

      {(state || terr || tse) && (
        <div className="crumbs">
          {state && <span>{state.name}</span>}
          {terr && <span>{terr.name}</span>}
          {tse && <span>{tse.name}</span>}
          {step === 'outlet' && !full && ctx && <button className="link small" onClick={() => { setSel({}); setStep('state'); }}>Change Territory / TSE</button>}
        </div>
      )}

      {step === 'state' && (
        <ul className="pick-list">
          {masters.states.map((s) => (
            <li key={s.id}><button className={ctx?.stateId === s.id ? 'current' : ''}
              onClick={() => { setSel({ stateId: s.id }); setStep('territory'); }}>{s.name}</button></li>
          ))}
        </ul>
      )}

      {step === 'territory' && (
        <ul className="pick-list">
          {territories.map((t) => (
            <li key={t.id}><button className={ctx?.territoryId === t.id ? 'current' : ''}
              onClick={() => { setSel({ ...sel, territoryId: t.id, tseId: null }); setStep('tse'); }}>{t.name}</button></li>
          ))}
          {!territories.length && <li className="empty">No territories for this state</li>}
        </ul>
      )}

      {step === 'tse' && (
        <ul className="pick-list">
          {tses.map((t) => (
            <li key={t.id}><button className={ctx?.tseId === t.id ? 'current' : ''}
              onClick={() => { setSel({ ...sel, tseId: t.id }); setStep('outlet'); setQ(''); }}>
              {t.name}<small>{t.code}</small></button></li>
          ))}
          {!tses.length && <li className="empty">No TSEs mapped to this territory</li>}
        </ul>
      )}

      {step === 'outlet' && (
        <>
          <input className="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="🔍 Search name, code or area" />
          {!q && recent.length > 0 && (
            <>
              <div className="list-h">RECENT OUTLETS</div>
              <ul className="pick-list recent">
                {recent.map((o) => (
                  <li key={o.id}><button className={ctx?.outletId === o.id ? 'current' : ''} onClick={() => onPick(o)}>
                    {o.name}<small>{o.area} · {o.outlet_code}</small></button></li>
                ))}
              </ul>
            </>
          )}
          <div className="list-h">{q ? `RESULTS (${filtered.length})` : `ALL OUTLETS — ${tse?.name || ''} (${outlets.length})`}</div>
          <ul className="pick-list">
            {filtered.map((o) => (
              <li key={o.id}><button className={ctx?.outletId === o.id ? 'current' : ''} onClick={() => onPick(o)}>
                {o.name}<small>{[o.area, o.city].filter(Boolean).join(', ')} · {o.outlet_code}</small></button></li>
            ))}
            {!filtered.length && <li className="empty">No outlet found</li>}
          </ul>
          <button className="btn-notlisted" onClick={onNotListed}>OUTLET NOT LISTED?</button>
        </>
      )}
    </main>
  );
}
