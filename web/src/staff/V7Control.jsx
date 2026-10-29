import React, { useEffect, useState } from 'react';
import { DEMO } from '../lib/supabase.js';
import { rpc, friendly } from '../lib/api.js';

export default function V7Control({ campaignId, isAdmin }) {
  const [status, setStatus] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    let current = true;
    setStatus(null); setError('');
    if (!DEMO && campaignId) rpc('get_prize_v7_status', { p_campaign: campaignId })
      .then((result) => { if (current) setStatus(result); })
      .catch((err) => {
        // The frontend can deploy before its database migration.
        if (current && !['PGRST202', '42883'].includes(err.code)
          && !/could not find the function|does not exist/i.test(err.message)) setError(friendly(err));
      });
    return () => { current = false; };
  }, [campaignId]);
  async function toggle() {
    setBusy(true); setError('');
    try {
      const result = await rpc('set_prize_v7_enabled', { p_campaign: campaignId, p_enabled: !status.enabled });
      setStatus(result);
    } catch (err) { setError(friendly(err)); }
    finally { setBusy(false); }
  }
  if (DEMO || (!status && !error)) return null;
  return <div className="s-note" style={{ margin: '0 0 12px' }}>
    {status && <>
      <label className="check"><input type="checkbox" checked={status.enabled} disabled={busy || !isAdmin} onChange={toggle} />
        <b>Version 7 {status.effective ? 'Active' : status.enabled ? 'Enabled (outside date window)' : 'Disabled'}</b>
      </label>
      <p>{status.selected_users} selected users · {status.starts_on} to {status.expires_on} (India time).</p>
      <p>₹10 / ₹5: 95% / 5%. With shades: ₹10 / ₹5 / shades: 90% / 6% / 4%.
        The two users without ₹5 stock use ₹10 / shades: 96% / 4%.</p>
      <p>Turning this off immediately returns subsequent draws to Version 6. Previous spins and stock movements are retained.</p>
    </>}
    {error && <div className="s-err">{error}</div>}
  </div>;
}
