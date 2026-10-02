import React, { useEffect, useState, useCallback } from 'react';
import { supabase } from '../lib/supabase.js';
import { rpc, selectAll } from '../lib/api.js';
import { loadMasters } from '../lib/masters.js';
import { defaultFilters } from './FilterBar.jsx';
import Dashboard from './Dashboard.jsx';
import Reports from './Reports.jsx';
import Transactions from './Transactions.jsx';
import Promoters from './Promoters.jsx';
import Flags from './Flags.jsx';
import OutletRequests from './OutletRequests.jsx';
import PrizePool from './PrizePool.jsx';
import PrizeConfig from './PrizeConfig.jsx';
import Campaigns from './Campaigns.jsx';
import Masters from './Masters.jsx';
import Users from './Users.jsx';
import Audit from './Audit.jsx';
import Exports from './Exports.jsx';
import OrgData from './OrgData.jsx';
import '../styles/staff.css';

const NAV = [
  { key: 'dashboard', label: 'Dashboard', icon: '▦', roles: ['admin', 'supervisor'] },
  { key: 'reports', label: 'Reports', icon: '☰', roles: ['admin', 'supervisor'] },
  { key: 'transactions', label: 'Transactions', icon: '⇄', roles: ['admin', 'supervisor'] },
  { key: 'promoters', label: 'Promoters & Stock', icon: '☺', roles: ['admin', 'supervisor'] },
  { key: 'flags', label: 'Flagged Activity', icon: '⚑', roles: ['admin', 'supervisor'] },
  { key: 'requests', label: 'Outlet Requests', icon: '＋', roles: ['admin', 'supervisor'] },
  { key: 'pool', label: 'Prize Pool', icon: '◎', roles: ['admin'], section: 'Admin' },
  { key: 'prizeconfig', label: 'Prize Structure', icon: '₹', roles: ['admin'] },
  { key: 'campaigns', label: 'Campaigns', icon: '⚙', roles: ['admin'] },
  { key: 'masters', label: 'Outlets & Masters', icon: '⌂', roles: ['admin'] },
  { key: 'users', label: 'Users', icon: '♟', roles: ['admin'] },
  { key: 'orgdata', label: 'Organization & Inventory', icon: '▤', roles: ['admin'], section: 'Data management' },
  { key: 'audit', label: 'Audit Log', icon: '⎙', roles: ['admin'] },
  { key: 'exports', label: 'Data Export', icon: '⇩', roles: ['admin'] },
];

export default function StaffApp({ profile, onLogout }) {
  const [page, setPage] = useState(() => (location.hash.slice(1) || 'dashboard'));
  const [menu, setMenu] = useState(false);
  const [filters, setFilters] = useState(defaultFilters);
  const [data, setData] = useState(null);
  const [err, setErr] = useState(null);
  const role = profile.role;

  const loadData = useCallback(async () => {
    try {
      const [loadedMasters, campaigns, promoters, supervisorOutlets] = await Promise.all([
        // Keep the large admin outlet directory out of the blocking page load.
        loadMasters({ force: true, includeOutletData: false }),
        selectAll('campaigns', '*', (q) => q.order('created_at', { ascending: false })),
        selectAll('app_users', 'id,full_name,login_id,is_active,role', (q) => q.eq('role', 'promoter').order('full_name')),
        role === 'supervisor' ? rpc('get_supervisor_outlet_master') : Promise.resolve(null),
      ]);
      const masters = supervisorOutlets
        ? {
            ...loadedMasters,
            tses: [...new Map(supervisorOutlets.filter((o) => o.tse_id && o.tse_name)
              .map((o) => [o.tse_id, { id: o.tse_id, code: o.tse_code, name: o.tse_name, territory_id: o.territory_id }])).values()],
            outlets: supervisorOutlets,
          }
        : loadedMasters;
      const outletsFull = supervisorOutlets || masters.outlets || [];
      setData((previous) => ({
        masters: role === 'admin' && previous?.outletsLoaded
          ? { ...masters, tses: previous.masters.tses, outlets: previous.masters.outlets }
          : masters,
        campaigns,
        promoters,
        outletsFull: role === 'supervisor' ? outletsFull : (previous?.outletsFull || []),
        outletsLoaded: role === 'supervisor' || !!previous?.outletsLoaded,
        outletsLoadError: previous?.outletsLoadError || '',
        role,
        profile,
      }));
    } catch (e) { setErr(e.message); }
  }, [role, profile]);

  useEffect(() => { loadData(); }, [loadData]);
  useEffect(() => {
    if (role !== 'admin' || !data || data.outletsLoaded) return undefined;
    let cancelled = false;
    Promise.all([
      selectAll('tses', 'id,code,name,territory_id', (q) => q.eq('status', 'active').order('name')),
      selectAll('outlets', 'id,outlet_code,name,area,city,beat,distributor,tse_id,status,source,external_ref', (q) => q.order('name')),
    ]).then(([tses, outlets]) => {
      if (cancelled) return;
      setData((previous) => previous && ({
        ...previous,
        masters: { ...previous.masters, tses, outlets },
        outletsFull: outlets,
        outletsLoaded: true,
        outletsLoadError: '',
      }));
    }).catch((error) => {
      if (cancelled) return;
      setData((previous) => previous && ({ ...previous, outletsLoaded: false, outletsLoadError: error.message }));
    });
    return () => { cancelled = true; };
  }, [role, !!data, data?.outletsLoaded]);
  useEffect(() => { location.hash = page; }, [page]);

  const nav = NAV.filter((n) => n.roles.includes(role));
  const Page = { dashboard: Dashboard, reports: Reports, transactions: Transactions, promoters: Promoters, flags: Flags,
    requests: OutletRequests, pool: PrizePool, prizeconfig: PrizeConfig, campaigns: Campaigns, masters: Masters,
    users: Users, orgdata: OrgData, audit: Audit, exports: Exports }[nav.some((n) => n.key === page) ? page : 'dashboard'];
  const current = nav.find((n) => n.key === page) || nav[0];

  return (
    <div className="s-app">
      <aside className={`s-side ${menu ? 'open' : ''}`}>
        <div className="s-brand">RIO SPIN &amp; WIN<small>{role === 'admin' ? 'Admin console' : 'Supervisor'}</small></div>
        <nav>
          {nav.map((n) => (
            <React.Fragment key={n.key}>
              {n.section && <div className="s-nav-section">{n.section}</div>}
              <button className={page === n.key ? 'on' : ''} onClick={() => { setPage(n.key); setMenu(false); }}>
                <span className="s-nav-ico">{n.icon}</span>{n.label}
              </button>
            </React.Fragment>
          ))}
        </nav>
        <div className="s-user">
          <div>{profile.full_name}<small>{profile.login_id}</small></div>
          <button className="s-btn ghost sm" onClick={onLogout}>Log out</button>
        </div>
      </aside>
      {menu && <div className="s-scrim" onClick={() => setMenu(false)} />}
      <main className="s-main">
        <header className="s-head">
          <button className="s-burger" onClick={() => setMenu(true)} aria-label="Menu">☰</button>
          <h1>{current.label}</h1>
        </header>
        {err && <div className="s-err">{err}</div>}
        {!data && !err && <div className="s-loading">Loading…</div>}
        {data && <Page data={data} reloadData={loadData} filters={filters} setFilters={setFilters} go={setPage} />}
      </main>
    </div>
  );
}

export { supabase };
