import React, { useEffect, useState } from 'react';
import { DEMO } from '../lib/supabase.js';
import { rpc, friendly } from '../lib/api.js';

const END_OF_WEEKEND = new Date('2026-11-30T00:00:00+05:30');

function formatIst(value) {
  if (!value) return 'not started';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return 'unknown';
  return new Intl.DateTimeFormat('en-IN', {
    dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Kolkata',
  }).format(date) + ' IST';
}

export default function WeekendMarketControl({ campaignId, isAdmin }) {
  const [status, setStatus] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');

  useEffect(() => {
    let current = true;
    setStatus(null);
    setError('');
    setMessage('');
    if (!DEMO && campaignId) {
      rpc('get_prize_weekend_market_status', { p_campaign: campaignId })
        .then((result) => { if (current) setStatus(result); })
        .catch((err) => {
          if (!current) return;
          if (/could not find the function|does not exist/i.test(err.message || '')) {
            setError('The weekend rule migration is not installed in the database yet. Apply the supplied SQL migration, then refresh this page.');
          } else setError(friendly(err));
        });
    }
    return () => { current = false; };
  }, [campaignId]);

  async function setEnabled(enabled) {
    if (!isAdmin || busy) return;
    if (!enabled && status?.effective && typeof window !== 'undefined'
      && !window.confirm('Roll back now? Future Thane and Mumbai draws will return to the existing V6/V7/V8 rules. Completed spins and stock records stay unchanged.')) return;
    setBusy(true);
    setError('');
    setMessage('');
    try {
      const result = await rpc('set_prize_weekend_market_enabled', {
        p_campaign: campaignId,
        p_enabled: enabled,
      });
      setStatus(result);
      setMessage(enabled
        ? 'Weekend rule is active. New eligible draws use the temporary settings.'
        : 'Weekend rule is off. New draws use the existing rules.');
    } catch (err) {
      setError(friendly(err));
    } finally {
      setBusy(false);
    }
  }

  if (DEMO) return null;

  const now = Date.now();
  const configuredEnd = status?.ends_at ? new Date(status.ends_at) : END_OF_WEEKEND;
  const windowOpen = now < configuredEnd.getTime();
  const active = Boolean(status?.effective);
  const enabled = Boolean(status?.enabled);

  return (
    <section className="s-note" style={{ margin: '0 0 12px', border: active ? '1px solid #b8860b' : undefined }} aria-live="polite">
      <h3 style={{ margin: '0 0 8px' }}>Weekend prize rule — Thane &amp; Mumbai</h3>
      {!status && !error && <p style={{ margin: '0 0 8px' }}>Checking weekend rule status…</p>}
      {status && <>
        <p style={{ margin: '0 0 8px' }}>
          <b>Status:</b> {active ? 'Active' : enabled ? 'Enabled but outside the active time window' : windowOpen ? 'Off' : 'Expired'}
          {' · '}<b>Markets:</b> Thane and Mumbai
          {' · '}<b>Ends:</b> {formatIst(status.ends_at)}
        </p>
        <p style={{ margin: '0 0 8px' }}>
          Ordinary prizes: <b>50% ₹5 snacks, 20% ₹10 snacks, 30% sunglasses</b> when sunglasses are in stock;
          without sunglasses stock, the existing <b>75% / 25%</b> snack fallback applies. The 50/20/30 balancing is shared across Thane and Mumbai spins with sunglasses stock.
        </p>
        <p style={{ margin: '0 0 8px' }}>
          While the regular Version 8 switch is enabled, existing Version 8 selected users in these markets get one speaker on daily spin 8 when available.
          The speaker is a separate Version 8 award, outside the 50/20/30 ordinary-prize mix. That spin uses the speaker instead of an ordinary prize; no later speaker is scheduled that day.
          Other selected users keep the existing spin-10 rule. Completed spins and stock movements are retained on rollback.
        </p>
        {status.starts_at && <p style={{ margin: '0 0 8px' }}><b>Started:</b> {formatIst(status.starts_at)}</p>}
        <p style={{ margin: '0 0 8px' }}>
          {status.market_users ?? 0} active users in these markets · {status.v8_selected_market_users ?? 0} selected Version 8 users ·
          {' '}{status.speakers_awarded_today ?? 0} Version 8 speakers awarded today.
        </p>
        {isAdmin && (active || enabled) ? (
          <button type="button" className="s-btn danger" disabled={busy} onClick={() => setEnabled(false)}>
            {busy ? 'Rolling back…' : 'Roll back to existing rules'}
          </button>
        ) : isAdmin && windowOpen ? (
          <button type="button" className="s-btn" disabled={busy || !status} onClick={() => setEnabled(true)}>
            {busy ? 'Activating…' : 'Activate weekend rule now'}
          </button>
        ) : null}
      </>}
      {message && <div className="s-ok" style={{ marginTop: 8 }}>{message}</div>}
      {error && <div className="s-err" style={{ marginTop: 8 }}>{error}</div>}
      {!isAdmin && status && <p className="muted" style={{ margin: '8px 0 0' }}>Only an administrator can activate or roll back this rule.</p>}
    </section>
  );
}
