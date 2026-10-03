import React, { useCallback, useEffect, useState } from 'react';
import { rpc, friendly } from '../lib/api.js';
import { supabase } from '../lib/supabase.js';
import { loadMasters, cachedMasters } from '../lib/masters.js';
import { store, deviceRef } from '../lib/store.js';
import { getCtx, saveCtx, pushRecent, getInflight, setInflight, clearInflight, clearAllForUser } from '../lib/session.js';
import { sound } from '../lib/sound.js';
import Home from './Home.jsx';
import OutletPicker from './OutletPicker.jsx';
import OutletRequest from './OutletRequest.jsx';
import SaleFlow from './SaleFlow.jsx';
import SpinScreen from './SpinScreen.jsx';
import WinScreen from './WinScreen.jsx';
import '../styles/promoter.css';

function useOnline() {
  const [on, setOn] = useState(navigator.onLine);
  useEffect(() => {
    const a = () => setOn(true); const b = () => setOn(false);
    addEventListener('online', a); addEventListener('offline', b);
    return () => { removeEventListener('online', a); removeEventListener('offline', b); };
  }, []);
  return on;
}

export default function PromoterApp({ profile, onLogout }) {
  const uid = profile.id;
  const online = useOnline();
  const [masters, setMasters] = useState(() => { const m = cachedMasters(); return m ? { ...m, outlets: [] } : m; });
  const [outletsLoading, setOutletsLoading] = useState(true);
  const [fullOutletsLoading, setFullOutletsLoading] = useState(false);
  const [outletLoadError, setOutletLoadError] = useState('');
  const [ctx, setCtx] = useState(() => getCtx(uid));
  const [home, setHome] = useState(() => store.get(`rio.home.${uid}`));
  const [flight, setFlight] = useState(() => getInflight(uid));
  const [spin, setSpin] = useState(null);
  const [view, setView] = useState(() => {
    const f = getInflight(uid);
    if (f && (f.stage === 'recorded' || f.stage === 'handover_done') && f.spinNo < f.spinsAllowed) return 'spin';
    return 'picker-outlet';
  });
  const [toast, setToast] = useState(null);
  const [soundOn, setSoundOn] = useState(sound.enabled());

  useEffect(() => {
    if (flight?.stage === 'handover_done' && flight.spinNo < flight.spinsAllowed) {
      const next = { ...flight, stage: 'recorded', spinNo: flight.spinNo + 1, spinId: null };
      setInflight(uid, next); setFlight(next);
    } else if (flight?.stage === 'handover_done' && flight.spinNo >= flight.spinsAllowed) {
      clearInflight(uid); setFlight(null); setView('home');
    }
  // Initial recovery only: subsequent handovers are handled by their controls.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const say = (msg, kind = 'info') => { setToast({ msg, kind }); setTimeout(() => setToast(null), 3800); };

  const refreshHome = useCallback(async () => {
    try {
      const h = await rpc('get_promoter_home', {}, { retries: 1 });
      setHome(h); store.set(`rio.home.${uid}`, h);
      // A prize is waiting to be handed over → always resume it (same result, never a re-draw)
      if (h.pending_spin) {
        setSpin(h.pending_spin);
        setView((v) => (v === 'spin' ? v : 'win'));
        return h;
      }
      // The isolated test promoter may have a partially completed multi-spin sale
      // after its browser-local recovery state was cleared. Recover only that account.
      if (profile.login_id === '9556600000') {
        const { data: testPromoter } = await supabase.from('promoters').select('promoter_code').eq('user_id', uid).maybeSingle();
        if (testPromoter?.promoter_code === 'TEST-9556600000') {
          const { data: sales } = await supabase.from('sales')
            .select('id,status,spins_used,spins_allowed,quantity,product_name,sku_code,outlet_id,created_at')
            .eq('promoter_id', uid).not('status', 'in', '(completed,cancelled)')
            .gt('spins_used', 0).order('created_at', { ascending: false }).limit(10);
          const sale = (sales || []).find((row) => row.spins_used < row.spins_allowed);
          if (sale && getInflight(uid)?.saleId !== sale.id) {
            const { data: items } = await supabase.from('sale_items').select('product_name,quantity').eq('sale_id', sale.id);
            const sku = (items || []).map((item) => `${item.product_name} × ${item.quantity}`).join(', ')
              || `${sale.product_name} × ${sale.quantity}`;
            const resumed = { saleId: sale.id, stage: 'recorded', spinNo: sale.spins_used + 1,
              spinsAllowed: sale.spins_allowed, sku, qty: sale.quantity, outletId: sale.outlet_id, at: Date.parse(sale.created_at) };
            setInflight(uid, resumed); setFlight(resumed); setSpin(null); setView('spin');
          }
        }
      }
      return h;
    } catch (e) {
      if (e.code === 'USER_DISABLED' || e.code === 'NOT_AUTHENTICATED') onLogout();
      return null;
    }
  }, [uid, onLogout, profile.login_id]);

  useEffect(() => {
    // The direct picker gets its assigned list from one purpose-built RPC.
    // Loading the entire outlet directory here duplicated that request and
    // delayed the picker on large outlet masters.
    Promise.all([loadMasters({ force: true, includeOutletData: false }), rpc('get_promoter_outlets')])
      .then(([m, outlets]) => { setMasters((current) => ({ ...(current || {}), ...m, outlets })); setOutletLoadError(''); })
      .catch((e) => { setOutletLoadError(friendly(e)); say(friendly(e), 'err'); })
      .finally(() => setOutletsLoading(false));
    refreshHome();
    // campaign sound default on first run
    if (store.get('rio.sound') == null && home?.campaign?.sound_default === false) sound.set(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => { if (online) refreshHome(); }, [online, refreshHome]);

  useEffect(() => {
    if (view !== 'picker-full') return;
    setFullOutletsLoading(true);
    loadMasters({ force: true }).then((m) => setMasters((current) => ({ ...(current || {}), ...m })))
      .catch((e) => say(friendly(e), 'err')).finally(() => setFullOutletsLoading(false));
  }, [view]);

  async function selectOutlet(outlet) {
    try {
      const res = await rpc('set_work_context', { p_outlet_id: outlet.id, p_device_ref: deviceRef() }, { retries: 2 });
      const picked = res.outlet;
      const next = {
        stateId: picked.state_id, stateName: picked.state_name,
        territoryId: picked.territory_id, territoryName: picked.territory_name,
        tseId: picked.tse_id, tseName: picked.tse_name,
        outletId: picked.outlet_id, outletName: picked.outlet_name, outletCode: picked.outlet_code,
        outletArea: picked.area, outletCity: picked.city, campaign: res.campaign || null,
      };
      saveCtx(uid, next); setCtx(next); pushRecent(uid, picked.outlet_id);
      setView('home');
      if (!res.campaign) say('No active campaign covers this outlet yet.', 'warn');
    } catch (e) {
      say(e.network ? 'You need an internet connection to load your assigned outlets.' : friendly(e), e.network ? 'warn' : 'err');
    }
  }

  function saleRecorded(f) {
    setInflight(uid, f); setFlight(f); setView('spin');
  }

  function spinResolved(result) {
    const f = { ...flight, stage: 'spun', spinId: result.spin_id };
    setInflight(uid, f); setFlight(f); setSpin(result);
  }

  async function handedOver(res) {
    const next = { ...flight, stage: 'handover_done' };
    setInflight(uid, next); setFlight(next);
    if (res?.low_stock) say(`LOW STOCK: ${res.prize_short_name} — only ${res.prize_left} left`, 'warn');
    else say(flight.spinNo < flight.spinsAllowed ? 'Prize handed over ✓' : 'All prizes handed over ✓', 'ok');
    await refreshHome();
  }

  function nextSpin() {
    const next = { ...flight, stage: 'recorded', spinNo: flight.spinNo + 1, spinId: null };
    setInflight(uid, next); setFlight(next); setSpin(null); setView('spin');
  }

  function startNewSale() {
    clearInflight(uid); setFlight(null); setSpin(null); setView('sale'); refreshHome();
  }

  function backHome() {
    clearInflight(uid); setFlight(null); setSpin(null); setView('home'); refreshHome();
  }

  function saleCancelled() {
    clearInflight(uid); setFlight(null); setView('home'); refreshHome();
  }

  async function resumePreviousCustomer() {
    // A prize already drawn is resumed from the authoritative pending-spin RPC.
    const h = await refreshHome();
    if (h?.pending_spin) return true;

    // If a multi-spin bill was interrupted between spins, recover its next
    // spin from the existing sale record instead of creating another bill.
    const { data: sales, error } = await supabase.from('sales')
      .select('id,spins_used,spins_allowed,quantity,product_name,sku_code,outlet_id,created_at')
      .eq('promoter_id', uid).not('status', 'in', '(completed,cancelled)')
      .gt('spins_used', 0).order('created_at', { ascending: false }).limit(10);
    if (error) throw error;
    const sale = (sales || []).find((row) => row.spins_used < row.spins_allowed);
    if (!sale) return false;

    const { data: items, error: itemsError } = await supabase.from('sale_items')
      .select('product_name,quantity').eq('sale_id', sale.id);
    if (itemsError) throw itemsError;
    const sku = (items || []).map((item) => `${item.product_name} × ${item.quantity}`).join(', ')
      || `${sale.product_name} × ${sale.quantity}`;
    const resumed = {
      saleId: sale.id, stage: 'recorded', spinNo: sale.spins_used + 1,
      spinsAllowed: sale.spins_allowed, sku, qty: sale.quantity,
      outletId: sale.outlet_id, at: Date.parse(sale.created_at),
    };
    setInflight(uid, resumed); setFlight(resumed); setSpin(null); setView('spin');
    return true;
  }

  const logout = () => { clearAllForUser(uid); onLogout(); };
  const toggleSound = () => { sound.set(!soundOn); setSoundOn(!soundOn); if (!soundOn) sound.win(); };

  // ---------- routing ----------
  if (view === 'spin' && flight) {
    return <SpinScreen flight={flight} onResolved={spinResolved} onLanded={() => setView('win')} onCancelled={saleCancelled}
                       prizes={masters?.prizes || []} say={say} />;
  }
  if (view === 'win' && spin) {
    return <WinScreen spin={spin} spinNo={flight?.spinNo || spin.spin_no || 1} spinsAllowed={flight?.spinsAllowed || 1}
      handedOver={flight?.stage === 'handover_done'} onHandedOver={handedOver} onNextSpin={nextSpin}
      onStartNewSale={startNewSale} onBackHome={backHome} say={say} />;
  }

  return (
    <div className="p-app">
      <header className="p-top">
        <img className="p-brand-logo" src="/brand/rio-logo-white.png" alt="Rio Spin &amp; Win" />
        <div className="p-top-right">
          <span className={`net ${online ? 'on' : 'off'}`}>{online ? '● Online' : '● Offline'}</span>
          <button className="icon-btn" onClick={toggleSound} aria-label="Toggle sound">{soundOn ? '🔊' : '🔇'}</button>
          <button className="icon-btn" onClick={logout} aria-label="Log out">⏻</button>
        </div>
      </header>

      {!masters && view !== 'home' && <div className="p-loading">Loading outlet list…</div>}

      {view === 'home' && (
        <Home profile={profile} home={home} ctx={ctx} online={online}
              onStart={() => { if (!ctx) setView('picker-outlet'); else setView('sale'); }}
              onChangeOutlet={() => setView('picker-outlet')}
              onChangeHierarchy={() => setView('picker-outlet')}
              onRefresh={refreshHome} />
      )}

      {(view === 'picker-outlet' || view === 'picker-full') && masters && (
        <OutletPicker masters={masters} ctx={ctx} uid={uid} full={view === 'picker-full'} direct={view === 'picker-outlet'}
                      loading={view === 'picker-outlet' ? outletsLoading : fullOutletsLoading}
                      loadError={view === 'picker-outlet' ? outletLoadError : ''}
                      onPick={selectOutlet} onCancel={ctx ? () => setView('home') : null}
                      onNotListed={() => setView('request')}
                      onReload={() => {
                        setOutletsLoading(true);
                        setOutletLoadError('');
                        return Promise.all([loadMasters({ force: true, includeOutletData: false }), rpc('get_promoter_outlets')])
                          .then(([m, outlets]) => { setMasters((current) => ({ ...(current || {}), ...m, outlets })); setOutletLoadError(''); })
                          .catch((e) => { setOutletLoadError(friendly(e)); say(friendly(e), 'err'); })
                          .finally(() => setOutletsLoading(false));
                      }} />
      )}

      {view === 'request' && masters && (
        <OutletRequest masters={masters} ctx={ctx} onDone={(ok) => { if (ok) say('Request sent for approval ✓', 'ok'); setView(ctx ? 'picker-outlet' : 'picker-full'); }} />
      )}

      {view === 'sale' && ctx && (
        <SaleFlow ctx={ctx} products={(masters?.products || []).filter((p) => !p.state_id || p.state_id === ctx.stateId)} online={online}
                  onRecorded={saleRecorded} onBack={() => setView('home')}
                  onResumePending={resumePreviousCustomer} />
      )}

      {toast && <div className={`toast ${toast.kind}`}>{toast.msg}</div>}
    </div>
  );
}
