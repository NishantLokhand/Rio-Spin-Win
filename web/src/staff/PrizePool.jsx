import React, { useState } from 'react';
import { rpc } from '../lib/api.js';
import { useAsync, Panel, Loading, DataTable, Kpi, fmt } from './ui.jsx';

export default function PrizePool({ data, go }) {
  const [campaign, setCampaign] = useState(data.campaigns[0]?.id);
  const c = data.campaigns.find((x) => x.id === campaign);
  const ps = useAsync(() => (campaign ? rpc('pool_status', { p_campaign: campaign }) : Promise.resolve(null)), [campaign]);
  const S = ps.data;

  const dist = S?.distribution || { total_spins: 0, giveaway_cost: 0, avg_giveaway_cost: 0, target_cost: 10, items: [] };
  const items = dist.items || [];

  return (
    <div className="s-page">
      <div className="filterbar"><div className="fb-dims">
        <select value={campaign || ''} onChange={(e) => setCampaign(e.target.value)}>
          {data.campaigns.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
        </select>
        {c && (
          <span className="muted">
            Engine: <b>Controlled Cumulative Random Allocation</b> · Scope: <b>{c.pool_scope}</b> · Out-of-stock: <b>{c.oos_mode}</b>
          </span>
        )}
        <button className="s-btn ghost sm" onClick={ps.reload}>↻</button>
      </div></div>

      {!S ? <Loading state={ps} /> : (
        <>
          <div className="kpis">
            <Kpi label="Total campaign spins" value={fmt.num(dist.total_spins)} />
            <Kpi label="Total giveaway spend" value={fmt.inr(dist.giveaway_cost)} />
            <Kpi
              label="Avg giveaway cost / spin"
              value={fmt.inr2(dist.avg_giveaway_cost)}
              tone={dist.avg_giveaway_cost > dist.target_cost ? 'warn' : 'good'}
              sub={`Target: ${fmt.inr2(dist.target_cost)}`}
            />
            <Kpi label="Active prize structures" value={S.configs.length} />
          </div>

          <Panel
            title="CAMPAIGN SPIN DISTRIBUTION"
            actions={<button className="s-btn ghost sm" onClick={() => go('prizeconfig')}>Configure Percentages</button>}
          >
            <div style={{ marginBottom: 12 }}>
              <span className="muted">
                Prizes are allocated using continuous cumulative deficit correction. Target counts dynamically scale with total spins.
              </span>
            </div>
            <DataTable
              rows={items}
              exportName="campaign_spin_distribution"
              columns={[
                { key: 'name', label: 'Prize', render: (r) => <span><b>{r.name}</b> <small className="muted">{r.tier}</small></span> },
                { key: 'unit_cost', label: 'Unit Cost', align: 'r', fmt: fmt.inr },
                { key: 'target_pct', label: 'Target %', align: 'r', fmt: fmt.pct },
                { key: 'target_count', label: 'Target Count', align: 'r', render: (r) => <b>{r.target_count}</b> },
                { key: 'actual_count', label: 'Actual Won', align: 'r', render: (r) => <b>{fmt.num(r.actual_count)}</b> },
                { key: 'actual_pct', label: 'Actual Share', align: 'r', fmt: fmt.pct },
                {
                  key: 'variance_pct',
                  label: 'Distribution Variance',
                  align: 'r',
                  render: (r) => {
                    const v = Number(r.variance_pct || 0);
                    const sign = v > 0 ? '+' : '';
                    const cls = Math.abs(v) > 2.0 ? (v > 0 ? 'txt-bad' : 'txt-warn') : 'muted';
                    return <span className={cls}>{sign}{v.toFixed(2)}%</span>;
                  },
                },
                { key: 'total_cost', label: 'Total Cost', align: 'r', fmt: fmt.inr },
              ]}
              empty="No spins recorded for this campaign yet."
            />
          </Panel>

          {S.configs.map((cfg) => (
            <Panel key={cfg.config_id} title={`Active Configuration ${cfg.state_name ? '— ' + cfg.state_name : '— Default'} · v${cfg.version}`}>
              <div className="pool-grid">
                <div>
                  <div className="pool-size">Reference Distribution Benchmark: <b>{cfg.pool_size || 200} Spins</b></div>
                  <table className="mini">
                    <thead>
                      <tr>
                        <th>Prize</th>
                        <th className="r">Target %</th>
                        <th className="r">Ref Qty</th>
                        <th className="r">Unit Cost</th>
                      </tr>
                    </thead>
                    <tbody>
                      {cfg.items.map((i) => (
                        <tr key={i.prize_id}>
                          <td>{i.name}</td>
                          <td className="r"><b>{fmt.pct(i.percentage)}</b></td>
                          <td className="r">{i.quantity}</td>
                          <td className="r muted">× {fmt.inr(i.unit_cost)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <div className="kpis compact">
                  <Kpi label="Expected giveaway cost" value={fmt.inr2(cfg.avg_cost)} tone={cfg.exceeds_target ? 'warn' : 'good'} sub={`Target ${fmt.inr2(cfg.target)}`} />
                  <Kpi label="Cost per 200 reference spins" value={fmt.inr(cfg.total_cost)} />
                </div>
              </div>
            </Panel>
          ))}
        </>
      )}
    </div>
  );
}
