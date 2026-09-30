import React, { useEffect, useState } from 'react';
import Confetti from './Confetti.jsx';
import { rpc, friendly } from '../lib/api.js';
import { sound } from '../lib/sound.js';

const DEFAULTS = {
  standard: { title: 'YOU WON! 🎉', sub: 'SNACK TIME!', icon: '🍿' },
  mid: { title: '🔥 YOU WON RIO DARE! 🔥', sub: 'LET THE GAMES BEGIN', icon: '🃏' },
  high: { title: '😎 YOU WON RIO SHADES!', sub: 'LOOKING COOL!', icon: '🕶️' },
  jackpot: { title: 'YOU WON RIO MINI BLUETOOTH SPEAKER!', sub: 'ENJOY YOUR NEW SPEAKER!', icon: '🔊' },
};

const PRIZE_COPY = {
  SNACK5: { title: 'YOU WON ₹5 SNACK!', sub: 'SNACK TIME!' },
  SNACK10: { title: 'YOU WON ₹10 SNACK!', sub: 'SNACK TIME!' },
  RIODARE: { title: 'YOU WON RIO DARE CARD GAME!', sub: 'LET THE GAMES BEGIN!' },
  SHADES: { title: 'YOU WON RIO SUNGLASSES!', sub: 'LOOKING COOL!' },
  SPEAKER: { title: 'YOU WON RIO MINI BLUETOOTH SPEAKER!', sub: 'ENJOY YOUR NEW SPEAKER!' },
};

const PRIZE_ART = {
  SNACK5: '/brand/snack-5.png',
  SNACK10: '/brand/snack-10.png',
  RIODARE: '/brand/rio-dare-cards.png',
  SHADES: '/brand/rio-shades.png',
  SPEAKER: '/brand/party-speaker.png',
};

export default function WinScreen({ spin, spinNo = 1, spinsAllowed = 1, handedOver = false, onHandedOver, onNextSpin, onStartNewSale, onBackHome, say }) {
  const p = spin.prize;
  const d = DEFAULTS[p.tier] || DEFAULTS.standard;
  const prizeCopy = PRIZE_COPY[p.code] || {};
  const prizeImage = p.image_url || PRIZE_ART[p.code];
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState(false);

  useEffect(() => {
    if (p.tier === 'jackpot') sound.jackpot(); else if (p.tier === 'high' || p.tier === 'mid') sound.big(); else sound.win();
    if (navigator.vibrate) navigator.vibrate(p.tier === 'jackpot' ? [200, 100, 200, 100, 400] : [120]);
  }, [p.tier]);

  async function handed() {
    setBusy(true);
    try {
      const res = await rpc('confirm_handover', { p_spin_id: spin.spin_id }, { retries: 4 });
      onHandedOver(res);
    } catch (e) { say(friendly(e), 'err'); setBusy(false); }
  }

  return (
    <div className={`win-screen tier-${p.tier}`}>
      <Confetti tier={p.tier} />
      <div className="win-rays" aria-hidden />
      <div className="win-body">
        <img className="win-brand-logo" src="/brand/rio-logo-white.png" alt="Rio Spin &amp; Win" />
        <h1 className="win-title">{prizeCopy.title || p.win_title || d.title}</h1>
        <div className="win-prize">
          {prizeImage ? <img src={prizeImage} alt={p.name} /> : <div className="win-icon">{d.icon}</div>}
        </div>
        <h2 className="win-sub">{prizeCopy.sub || p.win_subtitle || d.sub}</h2>
        <div className="win-name">{p.name}</div>
        <img className="win-gdwc-logo" src="/brand/gdwc-logo-white.png" alt="Good Drop Wine Cellars" />
      </div>

      <div className="handover">
        {spinsAllowed > 1 && <div className="spin-progress">SPIN {spinNo} OF {spinsAllowed}</div>}
        <div className="handover-label">PRIZE TO BE GIVEN</div>
        <div className="handover-prize">{p.name}</div>
        <div className="handover-code">Spin ID {spin.spin_code}</div>
        {handedOver ? (spinNo < spinsAllowed ? <button className="btn-handover" onClick={onNextSpin}>NEXT SPIN · {spinNo + 1} OF {spinsAllowed}</button> : <div className="handover-actions">
          <button className="btn-handover" onClick={onStartNewSale}>START NEW SALE</button>
          <button className="btn-secondary" onClick={onBackHome}>BACK TO HOME</button>
        </div>) : !confirm ? (
          <button className="btn-handover" disabled={busy} onClick={() => setConfirm(true)}>✅ PRIZE HANDED OVER</button>
        ) : (
          <div className="row">
            <button className="btn-secondary" disabled={busy} onClick={() => setConfirm(false)}>Back</button>
            <button className="btn-handover" disabled={busy} onClick={handed}>{busy ? 'Saving…' : 'YES, HANDED OVER'}</button>
          </div>
        )}
      </div>
    </div>
  );
}
