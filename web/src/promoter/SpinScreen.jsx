import React, { useEffect, useRef, useState } from 'react';
import Wheel, { SEGMENTS } from './Wheel.jsx';
import { rpc, friendly } from '../lib/api.js';
import { deviceRef } from '../lib/store.js';
import { sound } from '../lib/sound.js';

const FALLBACK_LABEL = { standard: ['SNACK ATTACK', 'TREAT YOURSELF', 'CRUNCH TIME'], mid: ['RIO DARE'], high: ['RIO SHADES'], jackpot: ['RIO PARTY JACKPOT'] };

function labelsFor(prize) {
  const own = (prize.wheel_label || '').split(',').map((s) => s.trim().toUpperCase()).filter(Boolean)
    .filter((l) => SEGMENTS.some((s) => s.label === l));
  return own.length ? own : FALLBACK_LABEL[prize.tier] || ['RIO SURPRISE'];
}

// CUSTOMER-FACING: brand + wheel only. No management data here.
export default function SpinScreen({ flight, onResolved, onLanded, onCancelled, say }) {
  const wheel = useRef(null);
  const [phase, setPhase] = useState('ready');   // ready | spinning | retry | landing
  const [handoff, setHandoff] = useState(true);
  const [confirmCancel, setConfirmCancel] = useState(false);
  const busy = useRef(false);

  useEffect(() => { const t = setTimeout(() => setHandoff(false), 4000); return () => clearTimeout(t); }, []);

  async function spin() {
    if (busy.current) return;
    busy.current = true; setHandoff(false);
    sound.unlock(); sound.whoosh();
    wheel.current.start(); setPhase('spinning');
    const started = Date.now();
    try {
      // Server draws the prize. Same sale id + spin no → same result on every retry.
      const result = await rpc('play_spin', { p_sale_id: flight.saleId, p_spin_no: flight.spinNo || 1, p_device_ref: deviceRef() }, { retries: 2, timeoutMs: 12000 });
      onResolved(result);
      const wait = Math.max(0, 700 - (Date.now() - started));
      await new Promise((r) => setTimeout(r, wait));
      setPhase('landing');
      await wheel.current.landOn(labelsFor(result.prize));
      onLanded();
    } catch (e) {
      busy.current = false;
      if (e.network) { wheel.current.pause(); setPhase('retry'); return; }
      wheel.current.reset(); setPhase('ready');
      say(friendly(e), 'err');
      if (e.code === 'SALE_CANCELLED' || e.code === 'SALE_NOT_FOUND') onCancelled();
    }
  }

  async function cancelSale() {
    try { await rpc('cancel_open_sale', { p_sale_id: flight.saleId, p_reason: 'customer left before spin' }, { retries: 2 }); onCancelled(); }
    catch (e) { say(friendly(e), 'err'); setConfirmCancel(false); }
  }

  return (
    <div className="spin-screen">
      <div className="spin-bg" aria-hidden />
      {phase === 'ready' && (
        <button className="spin-cancel" onClick={() => setConfirmCancel(true)} aria-label="Cancel sale">✕</button>
      )}
      <header className="spin-head">
        <img className="spin-brand" src="/brand/rio-logo-white.png" alt="Rio Spin &amp; Win" />
        <h1>BUY RIO. SPIN. WIN.</h1>
        <p className="tag">HAR SPIN MEIN PRIZE!</p>
      </header>

      <Wheel ref={wheel} onSwipe={spin} disabled={phase !== 'ready'} />

      <div className="spin-foot">
        {phase === 'ready' && <button className="btn-spin" onClick={spin}>SPIN NOW</button>}
        {phase === 'ready' && <p className="swipe-hint">or swipe the wheel!</p>}
        {(phase === 'spinning' || phase === 'landing') && <div className="spin-status">Good luck! 🤞</div>}
        {phase === 'retry' && (
          <div className="spin-retry">
            <p>We haven’t confirmed the result yet. Retry safely; the same sale cannot draw a second prize.</p>
            <button className="btn-spin small" onClick={() => { busy.current = false; spin(); }}>TRY AGAIN</button>
          </div>
        )}
        <img className="spin-gdwc-logo" src="/brand/gdwc-logo-white.png" alt="Good Drop Wine Cellars" />
      </div>

      {handoff && phase === 'ready' && (
        <div className="handoff" onClick={() => setHandoff(false)}>
          <div className="handoff-card">
            <div className="handoff-ico">📱➡️🙋</div>
            <b>HAND THE PHONE TO THE CUSTOMER</b>
            <small>{flight.sku} × {flight.qty}</small>
          </div>
        </div>
      )}

      {confirmCancel && (
        <div className="modal">
          <div className="modal-card">
            <b>Cancel this sale?</b>
            <p>Only if the customer left before spinning. Cancellations are logged.</p>
            <div className="row">
              <button className="btn-secondary" onClick={() => setConfirmCancel(false)}>Keep</button>
              <button className="btn-danger" onClick={cancelSale}>Cancel sale</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
