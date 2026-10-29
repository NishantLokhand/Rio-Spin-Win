import React, { useEffect, useState } from 'react';
import { DEMO } from '../lib/supabase.js';
import { rpc, friendly } from '../lib/api.js';

export default function V8Control({ campaignId, isAdmin }) {
  const [status, setStatus] = useState(null), [busy, setBusy] = useState(false), [error, setError] = useState('');
  useEffect(() => {
    let current = true;
    setStatus(null); setError('');
    if (!DEMO && campaignId) rpc('get_prize_v8_status', { p_campaign: campaignId })
      .then((result) => { if (current) setStatus(result); })
      .catch((err) => {
        if (current && !/could not find the function|does not exist/i.test(err.message)) setError(friendly(err));
      });
    return () => { current = false; };
  }, [campaignId]);
  async function toggle() {
    setBusy(true); setError('');
    try { setStatus(await rpc('set_prize_v8_enabled', { p_campaign: campaignId, p_enabled: !status.enabled })); }
    catch (err) { setError(friendly(err)); }
    finally { setBusy(false); }
  }
  if (DEMO || (!status && !error)) return null;
  return <div className="s-note" style={{ margin: '0 0 12px' }}>
    {status && <>
      <label className="check"><input type="checkbox" checked={status.enabled} disabled={busy || !isAdmin} onChange={toggle} />
        <b>Version 8 {status.effective ? 'Active' : status.enabled ? 'Enabled (outside date window)' : 'Disabled'}</b>
      </label>
      <p>{status.selected_users} selected users · {status.speakers_awarded_today} speakers awarded today.</p>
      <p>One speaker on each selected user's third daily spin, when available. All other spins follow their existing Version 7 or Version 6 rule.</p>
      <p>Turn off to roll back to ordinary prizes. Previous speaker wins and inventory records are retained.</p>
    </>}
    {error && <div className="s-err">{error}</div>}
  </div>;
}
