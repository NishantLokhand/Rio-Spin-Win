import React, { useEffect, useMemo, useState } from 'react';
import { rpc } from '../lib/api.js';
import { getRecent } from '../lib/session.js';

export default function OutletPicker({ masters, ctx, uid, full, direct = false, loading = false, loadError = '', onPick, onCancel, onNotListed, onReload }) {
  const [step, setStep] = useState(direct ? 'outlet' : (full || !ctx ? 'state' : 'outlet'));
  const [sel, setSel] = useState(() => (direct || full || !ctx ? {} : { stateId: ctx.stateId, territoryId: ctx.territoryId, tseId: ctx.tseId }));
  const [q, setQ] = useState('');
  const [addressQuery, setAddressQuery] = useState('');
  const [licenseQuery, setLicenseQuery] = useState('');
  const [serverResults, setServerResults] = useState(null);
  const [searchLoading, setSearchLoading] = useState(false);
  const [searchError, setSearchError] = useState(false);

  const state = masters.states.find((s) => s.id === sel.stateId);
  const terr = masters.territories.find((t) => t.id === sel.territoryId);
  const tse = masters.tses.find((t) => t.id === sel.tseId);

  const territories = useMemo(() => masters.territories.filter((t) => t.state_id === sel.stateId), [masters, sel.stateId]);
  const tses = useMemo(() => masters.tses.filter((t) => t.territory_id === sel.territoryId), [masters, sel.territoryId]);
  const outlets = useMemo(() => direct ? masters.outlets : masters.outlets.filter((o) => o.tse_id === sel.tseId), [masters, sel.tseId, direct]);

  const recent = useMemo(() => {
    const ids = getRecent(uid);
    return ids.map((id) => outlets.find((o) => o.id === id)).filter(Boolean).slice(0, 4);
  }, [uid, outlets]);

  const filtered = useMemo(() => {
    const s = q.trim().toLowerCase();
    if (!s) return outlets;
    return outlets.filter((o) => [o.name, o.outlet_code, o.area, o.city].some((v) => (v || '').toLowerCase().includes(s)));
  }, [q, outlets]);

  useEffect(() => {
    let current = true;
    const terms = [q.trim(), addressQuery.trim(), licenseQuery.trim()];
    if (!terms.some(Boolean)) {
      setServerResults(null); setSearchLoading(false); setSearchError(false);
      return () => { current = false; };
    }
    if (terms.some((term) => term && term.length < 2)) {
      setServerResults([]); setSearchLoading(false); setSearchError(false);
      return () => { current = false; };
    }
    setServerResults([]); setSearchError(false); setSearchLoading(true);
    const timer = setTimeout(async () => {
      setSearchLoading(true);
      try {
        const results = await rpc('search_authorized_outlets', {
          p_outlet_name: terms[0] || null, p_address: terms[1] || null, p_license_no: terms[2] || null,
          p_limit: 30, p_offset: 0,
        }, { retries: 1 });
        if (current) setServerResults(results || []);
      } catch {
        if (current) { setServerResults(null); setSearchError(true); }
      } finally { if (current) setSearchLoading(false); }
    }, terms.some(Boolean) ? 250 : 0);
    return () => { current = false; clearTimeout(timer); };
  }, [q, addressQuery, licenseQuery]);

  async function loadMoreSearchResults() {
    if (!serverResults?.length || searchLoading) return;
    const terms = [q.trim(), addressQuery.trim(), licenseQuery.trim()];
    setSearchLoading(true);
    try {
      const more = await rpc('search_authorized_outlets', {
        p_outlet_name: terms[0] || null, p_address: terms[1] || null, p_license_no: terms[2] || null,
        p_limit: 30, p_offset: serverResults.length,
      }, { retries: 1 });
      setServerResults((current) => [...(current || []), ...(more || [])]);
    } catch { setSearchError(true); }
    finally { setSearchLoading(false); }
  }

  const Title = { state: 'SELECT STATE', territory: 'SELECT TERRITORY', tse: 'SELECT MAPPED TSE', outlet: 'SELECT OUTLET' }[step];

  const back = () => {
    if (direct) return;
    if (step === 'territory') setStep('state');
    else if (step === 'tse') setStep('territory');
    else if (step === 'outlet' && (full || !ctx)) setStep('tse');
    else onCancel && onCancel();
  };

  return (
    <main className="picker">
      <div className="picker-top">
        {!direct && (step !== 'state' || onCancel) && <button className="back" onClick={step === 'state' ? onCancel : back}>‹</button>}
        <h2>{Title}</h2>
        {step === 'state' && <button className="link small" onClick={onReload}>↻ Refresh list</button>}
      </div>

      {!direct && (state || terr || tse) && (
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
          <div className="outlet-search-fields">
            <input className="search" aria-label="Search outlet name" value={q} onChange={(e) => setQ(e.target.value)} placeholder="🔍 Outlet name, code, area or city" />
            <input className="search" aria-label="Search outlet address" value={addressQuery} onChange={(e) => setAddressQuery(e.target.value)} placeholder="Address, locality, road or landmark" />
            <input className="search" aria-label="Search outlet licence number" value={licenseQuery} onChange={(e) => setLicenseQuery(e.target.value)} placeholder="Licence No. (full or partial)" />
          </div>
          {searchError && <p className="outlet-search-fallback" role="status">Enhanced search is unavailable right now. Your existing outlet list is still available.</p>}
          {!q && !addressQuery && !licenseQuery && serverResults === null && recent.length > 0 && (
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
          <div className="list-h">{loading ? 'LOADING OUTLETS…' : searchLoading ? 'SEARCHING AUTHORIZED OUTLETS…' : (q || addressQuery || licenseQuery) ? `RESULTS (${serverResults?.[0]?.total_count ?? filtered.length})` : direct ? 'YOUR AUTHORIZED OUTLETS' : `AUTHORIZED OUTLETS — ${tse?.name || ''}`}</div>
          <ul className="pick-list">
            {!loading && (serverResults === null ? filtered : serverResults).map((o) => (
              <li key={`${o.id}:${o.directory_record_id || 'operational'}`}><button className={ctx?.outletId === o.id ? 'current' : ''} onClick={() => onPick(o)}>
                {o.name}<small>Address: {o.address || [o.area, o.city].filter(Boolean).join(', ') || 'unavailable'} · Licence No.: {o.license_no || 'unavailable'} · Code: {o.outlet_code}</small></button></li>
            ))}
            {(loading || searchLoading) && <li className="empty">{loading ? 'Loading your assigned outlets…' : 'Searching your authorized outlets…'}</li>}
            {!loading && loadError && <li className="empty">Could not load the outlet list. {loadError} <button className="link small" onClick={onReload}>Retry</button></li>}
            {!loading && !searchLoading && !loadError && !(serverResults === null ? filtered : serverResults).length && <li className="empty">{(q || addressQuery || licenseQuery) && [q, addressQuery, licenseQuery].some((term) => term.trim().length === 1) ? 'Enter at least 2 characters to search.' : direct ? 'No outlets are assigned to this account yet. Ask an administrator to link your promoter record and assign your outlet in Organization & Inventory.' : 'No outlet found'}</li>}
          </ul>
          {serverResults?.length >= 30 && Number(serverResults[0]?.total_count || 0) > serverResults.length && <button className="link small" disabled={searchLoading} onClick={loadMoreSearchResults}>Load more authorized outlets</button>}
          <button className="btn-notlisted" onClick={onNotListed}>OUTLET NOT LISTED?</button>
        </>
      )}
    </main>
  );
}
