import React, { useState } from 'react';
import { rpc } from '../lib/api.js';
import { useAsync, Panel, Loading, DataTable, Kpi, fmt } from './ui.jsx';

export default function PrizePool({ data, go }) {
  const [campaign, setCampaign] = useState(data.campaigns[0]?.id);
  const c = data.campaigns.find((x) => x.id === campaign);
  const ps = useAsync(() => (campaign ? rpc('pool_status', { p_campaign: campaign }) : Promise.resolve(null)), [campaign]);
  const S = ps.data;

  return (
    <div className="s-page">
      <div className="filterbar"><div className="fb-dims">
        <select value={campaign || ''} onChange={(e) => setCampaign(e.target.value)}>
          {data.campaigns.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
        </select>
        {c && <span className="muted">Rule: <b>{c.draw_strategy.replace('_', ' ')}</b> · pool per <b>{c.pool_scope}</b> · out-of-stock: <b>{c.oos_mode}</b> · on config change: <b>{c.config_change_mode.replace('_', ' ')}</b></span>}
        <button className="s-btn ghost sm" onClick={ps.reload}>↻</button>
      </div></div>

      {!S ? <Loading state={ps} /> : (
        <>
          {S.configs.map((cfg) => (
            <Panel key={cfg.config_id} title={`CURRENT POOL ${cfg.state_name ? '— ' + cfg.state_name : '— default'} · v${cfg.version}`}
                   actions={<button className="s-btn ghost sm" onClick={() => go('prizeconfig')}>Edit structure</button>}>
              <div className="pool-grid">
                <div>
                  <div className="pool-size">Pool Size: <b>{cfg.pool_size} Spins</b></div>
                  <table className="mini">
                    <tbody>{cfg.items.map((i) => (
                      <tr key={i.prize_id}><td>{i.name}</td><td className="r"><b>{i.quantity}</b></td><td className="r muted">× {fmt.inr(i.unit_cost)}</td></tr>
                    ))}</tbody>
                  </table>
                </div>
                <div className="kpis compact">
                  <Kpi label="Total prize cost" value={fmt.inr(cfg.total_cost)} />
                  <Kpi label="Average cost" value={fmt.inr2(cfg.avg_cost)} tone={cfg.exceeds_target ? 'warn' : 'good'} sub={`Target ${fmt.inr2(cfg.target)}`} />
                </div>
              </div>
            </Panel>
          ))}
          {!S.configs.length && <div className="s-err">No active prize structure for this campaign.</div>}

          <div className="kpis">
            <Kpi label="Open pools" value={S.totals.open_pools} />
            <Kpi label="Spins used (open pools)" value={`${fmt.num(S.totals.used)} / ${fmt.num(S.totals.capacity)}`} />
            <Kpi label="Spins remaining (open pools)" value={fmt.num(S.totals.capacity - S.totals.used)} />
            <Kpi label="Completed pools" value={S.totals.completed_pools} />
            <Kpi label="Total spins all pools" value={fmt.num(S.totals.total_spins_all_pools)} />
          </div>

          <Panel title="Open pools — aggregate remaining quantities (sequence is never shown)">
            <DataTable rows={S.pools.map((p) => ({ ...p, pos: `${p.used} / ${p.size}`, rem: Object.entries(p.remaining_by_prize || {}).map(([k, v]) => `${k} ${v}`).join(' · ') }))}
              exportName="open_pools" columns={[
                { key: 'owner', label: c?.pool_scope === 'promoter' ? 'Promoter' : 'Scope' }, { key: 'pool_no', label: 'Pool #', align: 'r' },
                { key: 'config_version', label: 'Config v', align: 'r' },
                { key: 'pos', label: 'Spins used' }, { key: 'remaining', label: 'Remaining', align: 'r' },
                { key: 'rem', label: 'Remaining by prize' },
                { key: 'deferred', label: 'Deferred (no stock)', align: 'r', render: (r) => r.deferred ? <b className="txt-bad">{r.deferred}</b> : '0' },
              ]} empty="No pools yet — one is created automatically at a promoter's first spin." />
          </Panel>
        </>
      )}
    </div>
  );
}
