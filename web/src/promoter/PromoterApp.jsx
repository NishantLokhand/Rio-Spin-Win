import React, { useCallback, useEffect, useState } from 'react';
import { rpc, friendly } from '../lib/api.js';
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
  const [masters, setMasters] = useState(cachedMasters());
  const [ctx, setCtx] = useState(() => getCtx(uid));
  const [home, setHome] = useState(() => store.get(`rio.home.${uid}`));
  const [flight, setFlight] = useState(() => getInflight(uid));
  const [spin, setSpin] = useState(null);
  const [view, setView] = useState(() => {
    const f = getInflight(uid);
    if (f && f.stage === 'recorded') return 'spin';
    return getCtx(uid) ? 'home' : 'picker-full';
  });
  const [toast, setToast] = useState(null);
  const [soundOn, setSoundOn] = useState(sound.enabled());

  const say = (msg, kind = 'info') => { setToast({ msg, kind }); setTimeout(() => setToast(null), 3800); };

  const refreshHome = useCallback(async () => {
    try {
      const h = await rpc('get_promoter_home', {}, { retries: 1 });
      setHome(h); store.set(`rio.home.${uid}`, h);
      // A prize is waiting to be handed over → always resume it (same result, never a re-draw)
      if (h.pending_spin) {
        setSpin(h.pending_spin);
        setView((v) => (v === 'spin' ? v : 'win'));
      }
      return h;
    } catch (e) {
      if (e.code === 'USER_DISABLED' || e.code === 'NOT_AUTHENTICATED') onLogout();
      return null;
    }
  }, [uid, onLogout]);

  useEffect(() => {
    loadMasters().then(setMasters).catch(() => {});
    refreshHome();
    // campaign sound default on first run
    if (store.get('rio.sound') == null && home?.campaign?.sound_default === false) sound.set(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => { if (online) refreshHome(); }, [online, refreshHome]);

  async function selectOutlet(outlet) {
    const m = masters;
    const tse = m.tses.find((t) => t.id === outlet.tse_id);
    const terr = m.territories.find((t) => t.id === tse?.territory_id);
    const st = m.states.find((s) => s.id === terr?.state_id);
    const next = {
      stateId: st?.id, stateName: st?.name, territoryId: terr?.id, territoryName: terr?.name,
      tseId: tse?.id, tseName: tse?.name,
      outletId: outlet.id, outletName: outlet.name, outletCode: outlet.outlet_code, outletArea: outlet.area, outletCity: outlet.city,
      campaign: ctx?.campaign || null,
    };
    saveCtx(uid, next); setCtx(next); pushRecent(uid, outlet.id);
    setView('home');
    try {
      const res = await rpc('set_work_context', { p_outlet_id: outlet.id, p_device_ref: deviceRef() }, { retries: 2 });
      const withCampaign = { ...next, campaign: res.campaign };
      saveCtx(uid, withCampaign); setCtx(withCampaign);
      if (!res.campaign) say('No active campaign covers this outlet yet.', 'warn');
    } catch (e) {
      if (!e.network) say(friendly(e), 'err');
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
    clearInflight(uid); setFlight(null); setSpin(null);
    setView('home');
    if (res?.low_stock) say(`LOW STOCK: ${res.prize_short_name} — only ${res.prize_left} left`, 'warn');
    else say('Transaction completed ✓', 'ok');
    refreshHome();
  }

  function saleCancelled() {
    clearInflight(uid); setFlight(null); setView('home'); refreshHome();
  }

  const logout = () => { clearAllForUser(uid); onLogout(); };
  const toggleSound = () => { sound.set(!soundOn); setSoundOn(!soundOn); if (!soundOn) sound.win(); };

  // ---------- routing ----------
  if (view === 'spin' && flight) {
    return <SpinScreen flight={flight} onResolved={spinResolved} onLanded={() => setView('win')} onCancelled={saleCancelled}
                       prizes={masters?.prizes || []} say={say} />;
  }
  if (view === 'win' && spin) {
    return <WinScreen spin={spin} onHandedOver={handedOver} say={say} />;
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
              onStart={() => { if (!ctx) setView('picker-full'); else setView('sale'); }}
              onChangeOutlet={() => setView(ctx ? 'picker-outlet' : 'picker-full')}
              onChangeHierarchy={() => setView('picker-full')}
              onRefresh={refreshHome} />
      )}

      {(view === 'picker-outlet' || view === 'picker-full') && masters && (
        <OutletPicker masters={masters} ctx={ctx} uid={uid} full={view === 'picker-full'}
                      onPick={selectOutlet} onCancel={ctx ? () => setView('home') : null}
                      onNotListed={() => setView('request')}
                      onReload={() => loadMasters({ force: true }).then(setMasters).catch((e) => say(friendly(e), 'err'))} />
      )}

      {view === 'request' && masters && (
        <OutletRequest masters={masters} ctx={ctx} onDone={(ok) => { if (ok) say('Request sent for approval ✓', 'ok'); setView(ctx ? 'picker-outlet' : 'picker-full'); }} />
      )}

      {view === 'sale' && ctx && (
        <SaleFlow ctx={ctx} products={(masters?.products || []).filter((p) => !p.state_id || p.state_id === ctx.stateId)} online={online}
                  onRecorded={saleRecorded} onBack={() => setView('home')}
                  onPending={() => refreshHome()} say={say} />
      )}

      {toast && <div className={`toast ${toast.kind}`}>{toast.msg}</div>}
    </div>
  );
}
