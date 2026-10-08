import React, { useEffect, useMemo, useState } from 'react';
import { rpc } from '../lib/api.js';

export default function OutletPicker({ masters, ctx, loading = false, loadError = '', onPick, onCancel, onNotListed }) {
  const [q, setQ] = useState('');
  const [licenseQuery, setLicenseQuery] = useState('');
  const [serverResults, setServerResults] = useState(null);
  const [searchLoading, setSearchLoading] = useState(false);
  const [searchError, setSearchError] = useState(false);
  const outlets = useMemo(() => masters.outlets || [], [masters.outlets]);
  const hasSearch = Boolean(q.trim() || licenseQuery.trim());

  const filtered = useMemo(() => {
    const nameTerm = q.trim().toLowerCase();
    const licenseTerm = licenseQuery.trim().toLowerCase();
    if (!nameTerm && !licenseTerm) return [];
    return outlets.filter((o) => {
      const nameMatch = !nameTerm || [o.name, o.outlet_code, o.area, o.city, o.beat, o.state_code]
        .some((v) => (v || '').toLowerCase().includes(nameTerm));
      const licenseMatch = !licenseTerm || (o.license_no || '').toLowerCase().includes(licenseTerm);
      return nameMatch && licenseMatch;
    });
  }, [q, licenseQuery, outlets]);

  useEffect(() => {
    let current = true;
    const terms = [q.trim(), licenseQuery.trim()];
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
          p_outlet_name: terms[0] || null, p_address: null, p_license_no: terms[1] || null,
          p_limit: 30, p_offset: 0,
        }, { retries: 1 });
        if (current) setServerResults(results || []);
      } catch {
        if (current) { setServerResults(null); setSearchError(true); }
      } finally { if (current) setSearchLoading(false); }
    }, terms.some(Boolean) ? 250 : 0);
    return () => { current = false; clearTimeout(timer); };
  }, [q, licenseQuery]);

  async function loadMoreSearchResults() {
    if (!serverResults?.length || searchLoading) return;
    const terms = [q.trim(), licenseQuery.trim()];
    setSearchLoading(true);
    try {
      const more = await rpc('search_authorized_outlets', {
        p_outlet_name: terms[0] || null, p_address: null, p_license_no: terms[1] || null,
        p_limit: 30, p_offset: serverResults.length,
      }, { retries: 1 });
      setServerResults((current) => [...(current || []), ...(more || [])]);
    } catch { setSearchError(true); }
    finally { setSearchLoading(false); }
  }

  return (
    <main className="picker">
      <div className="picker-top">
        {onCancel && <button className="back" onClick={onCancel}>‹</button>}
        <h2>SELECT OUTLET</h2>
      </div>

        <>
          <div className="outlet-search-fields">
            <input className="search" aria-label="Search outlet name" value={q} onChange={(e) => setQ(e.target.value)} placeholder="🔍 Outlet name, code, area or city" />
            <input className="search" aria-label="Search outlet licence number" value={licenseQuery} onChange={(e) => setLicenseQuery(e.target.value)} placeholder="Licence No. (full or partial)" />
          </div>
          {searchError && hasSearch && <p className="outlet-search-fallback" role="status">Enhanced search is unavailable. Showing matching outlets from the available local list.</p>}
          {!hasSearch && <p className="outlet-search-hint">Search by outlet name, area, city, code, or licence number. Results appear here after you search.</p>}
          {hasSearch && <div className="list-h">{loading || searchLoading ? 'SEARCHING ALL OUTLETS…' : `RESULTS (${serverResults !== null ? (serverResults[0]?.total_count ?? 0) : filtered.length})`}</div>}
          {hasSearch && <ul className="pick-list">
            {(() => {
              const results = serverResults === null ? filtered : serverResults;
              return results.map((o, index) => {
                const tier = o.match_tier || 'available';
                const tierTitle = { exact: '100% MATCH', close: '50–99% MATCH', broad: 'BELOW 50% MATCH', available: 'AVAILABLE MATCHES' }[tier];
                const previousTier = index > 0 ? (results[index - 1].match_tier || 'available') : null;
                const stateName = { UP: 'Uttar Pradesh', MH: 'Maharashtra' }[o.state_code] || o.state_code || 'Unavailable';
                return <React.Fragment key={`${o.id}:${o.directory_record_id || 'operational'}`}>
                  {tier !== previousTier && <li className="match-group">{tierTitle}</li>}
                  <li><button className={ctx?.outletId === o.id ? 'current' : ''} onClick={() => onPick(o)}>
                    {o.name}<small>State: {stateName} · Area: {o.area || 'Unavailable'} · Licence No.: {o.license_no || 'Unavailable'}{o.outlet_code ? ` · Code: ${o.outlet_code}` : ''}</small>
                  </button></li>
                </React.Fragment>;
              });
            })()}
            {(loading || searchLoading) && <li className="empty">{loading ? 'Loading outlet data…' : 'Searching all outlets…'}</li>}
            {!loading && !searchLoading && !(serverResults === null ? filtered : serverResults).length && <li className="empty">{[q, licenseQuery].some((term) => term.trim().length === 1) ? 'Enter at least 2 characters to search.' : searchError ? `No matching outlets in the available local list. ${loadError}` : 'No outlet found.'}</li>}
          </ul>}
          {serverResults?.length >= 30 && Number(serverResults[0]?.total_count || 0) > serverResults.length && <button className="link small" disabled={searchLoading} onClick={loadMoreSearchResults}>Load more outlets</button>}
          <button className="btn-notlisted" onClick={onNotListed}>OUTLET NOT LISTED?</button>
        </>
    </main>
  );
}
