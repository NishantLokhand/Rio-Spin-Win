import React, { useState } from 'react';
import { supabase, loginEmail, DEMO } from './lib/supabase.js';

export default function Login({ error: initialError }) {
  const [login, setLogin] = useState('');
  const [pin, setPin] = useState('');
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(initialError || '');

  async function submit(e) {
    e.preventDefault();
    if (!login || !pin) return;
    setBusy(true); setError('');
    const { error } = await supabase.auth.signInWithPassword({ email: loginEmail(login), password: pin });
    setBusy(false);
    if (error) setError(/fetch|network/i.test(error.message) ? 'No network connection.' : 'Wrong mobile/username or PIN.');
  }

  return (
    <div className="login">
      <div className="login-hero">
        <img className="login-brand-logo" src="/brand/rio-logo-white.png" alt="Rio Spin &amp; Win" />
        <img className="login-gdwc-logo" src="/brand/gdwc-logo-white.png" alt="Good Drop Wine Cellars" />
        <p className="brand-sub">Field App</p>
      </div>
      <form className="login-card" onSubmit={submit}>
        <label>Mobile number or username
          <input value={login} onChange={(e) => setLogin(e.target.value)} inputMode="text" autoComplete="username"
                 placeholder="e.g. 9876500001" autoCapitalize="none" />
        </label>
        <label>PIN / Password
          <div className="pin-row">
            <input value={pin} onChange={(e) => setPin(e.target.value)} type={show ? 'text' : 'password'}
                   autoComplete="current-password" placeholder="••••••" />
            <button type="button" className="ghost" onClick={() => setShow(!show)}>{show ? 'Hide' : 'Show'}</button>
          </div>
        </label>
        {error && <div className="err">{error}</div>}
        <button className="btn-primary big" disabled={busy}>{busy ? 'Signing in…' : 'LOG IN'}</button>
      </form>
      {DEMO && (
        <div className="demo-card">
          <b>Demo logins</b> (tap to fill)
          {[['Promoter — Ravi (Lucknow)', '9876500001', '111111'], ['Promoter — Sneha (Lucknow)', '9876500002', '111111'],
            ['Supervisor — Lucknow', 'sup.lucknow', '222222'], ['Admin', 'admin', 'admin123']].map(([label, l, p]) => (
            <button key={l} type="button" onClick={() => { setLogin(l); setPin(p); }}>{label}<small>{l} / {p}</small></button>
          ))}
          <button type="button" className="demo-reset" onClick={() => { if (confirm('Erase all demo data and start fresh?')) { supabase.reset(); location.reload(); } }}>
            Reset demo data
          </button>
          <small>Data is stored only in this browser. Prizes in demo mode are drawn on this device — for testing only.</small>
        </div>
      )}
    </div>
  );
}
