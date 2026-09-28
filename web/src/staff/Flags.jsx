import React, { useState } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, friendly } from '../lib/api.js';
import { useAsync, Panel, Loading, DataTable, Tabs, Badge, fmt } from './ui.jsx';

const LABEL = {
  rapid_spins: 'Spins too close together', high_spin_count: 'Unusually high spin count',
  high_value_concentration: 'High-value win concentration', outside_hours: 'Outside working hours',
  incomplete_transactions: 'Incomplete transactions', excess_cancellations: 'Excessive cancellations',
  repeated_outlet_not_listed: 'Repeated "Outlet Not Listed"', stock_discrepancy: 'Stock discrepancy',
  abnormal_redemption: 'Abnormal redemption', manual: 'Raised manually',
};

export default function Flags({ data }) {
  const [status, setStatus] = useState('open');
  const [err, setErr] = useState('');
  const flags = useAsync(async () => {
    const { data: rows, error } = await supabase.from('activity_flags').select('*').eq('status', status).order('updated_at', { ascending: false }).limit(500);
    if (error) throw error; return rows;
  }, [status]);
  const users = Object.fromEntries(data.promoters.map((u) => [u.id, u.full_name]));

  async function review(f, st) {
    const note = st === 'dismissed' ? prompt('Reason for dismissing?') : prompt('Review note (optional)') ?? '';
    if (note === null) return;
    try { await rpc('review_flag', { p_flag_id: f.id, p_status: st, p_note: note }); flags.reload(); }
    catch (e) { setErr(friendly(e)); }
  }

  return (
    <div className="s-page">
      <Tabs value={status} onChange={setStatus} tabs={[{ key: 'open', label: 'FLAGGED ACTIVITY (open)' }, { key: 'reviewed', label: 'Reviewed' }, { key: 'dismissed', label: 'Dismissed' }]} />
      {err && <div className="s-err">{err}</div>}
      <Panel>
        {!flags.data ? <Loading state={flags} /> : (
          <DataTable rows={flags.data.map((f) => ({ ...f, promoter: users[f.promoter_id] || '—', type: LABEL[f.flag_type] || f.flag_type }))}
            exportName={`flags_${status}`} columns={[
              { key: 'flag_date', label: 'Date', fmt: fmt.date },
              { key: 'promoter', label: 'Promoter' },
              { key: 'severity', label: 'Severity', render: (r) => <Badge tone={{ high: 'red', medium: 'amber', low: 'grey' }[r.severity]}>{r.severity}</Badge> },
              { key: 'type', label: 'Flag' },
              { key: 'reason', label: 'Reason' },
              { key: 'occurrences', label: 'Times', align: 'r' },
              { key: 'review_note', label: 'Review note' },
              ...(status === 'open' ? [{ key: 'act', label: '', noExport: true, render: (r) => (
                <div className="row-actions">
                  <button className="s-btn sm" onClick={() => review(r, 'reviewed')}>Reviewed</button>
                  <button className="s-btn ghost sm" onClick={() => review(r, 'dismissed')}>Dismiss</button>
                </div>) }] : []),
            ]} empty="No flagged activity 🎉" />
        )}
      </Panel>
    </div>
  );
}
