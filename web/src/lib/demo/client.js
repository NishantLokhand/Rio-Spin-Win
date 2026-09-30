// A stand-in for the Supabase JS client used in DEMO MODE (no backend).
// Implements only the query/auth/rpc surface this app uses; data lives in this browser's localStorage.
import { Engine, DemoError } from './engine.js';

const LATENCY = 120;
const wait = (v) => new Promise((r) => setTimeout(() => r(v), LATENCY));
const clone = (x) => (x == null ? x : JSON.parse(JSON.stringify(x)));
const RPCS = new Set(['set_work_context', 'record_sale', 'capture_sale_customer', 'play_spin', 'confirm_handover', 'my_pending_spin', 'cancel_open_sale', 'get_promoter_home',
  'submit_outlet_request', 'adjust_stock', 'issue_stock_kit', 'resolve_spin', 'review_outlet_request', 'review_flag', 'raise_flag', 'report_summary', 'prize_distribution_report',
  'dashboard_kpis', 'run_flag_scan', 'save_prize_config', 'pool_status', 'import_outlets', 'verify_audit_chain']);
const MASTER = new Set(['states', 'territories', 'tses', 'outlets', 'products', 'prizes', 'campaigns', 'campaign_states', 'campaign_territory_budgets',
  'campaign_products', 'campaign_promoters', 'app_users', 'promoters']);
const PROMOTER_SCOPED = { sales: 'promoter_id', spins: 'promoter_id', promoter_sessions: 'promoter_id', promoter_inventory: 'promoter_id',
  inventory_movements: 'promoter_id', outlet_requests: 'promoter_id', promoters: 'user_id' };

function getPath(r, path) {
  if (path.includes('->>')) { const [a, b] = path.split('->>'); return r[a]?.[b]; }
  return path.split('.').reduce((o, k) => (o == null ? o : o[k]), r);
}

export function createDemoClient() {
  const E = new Engine();
  const SKEY = 'rio.demo.session';
  const listeners = new Set();
  const readSession = () => { try { return JSON.parse(localStorage.getItem(SKEY)); } catch { return null; } };
  const setUid = () => { E.load(); E.uid = readSession()?.user?.id || null; };
  const emit = (ev, s) => listeners.forEach((cb) => setTimeout(() => cb(ev, s), 0));

  function visibleRows(table) {
    const u = E.me(); const db = E.db;
    if (table === 'prize_pool_slots') throw new DemoError('permission denied for table prize_pool_slots');
    if (table === 'v_transactions') return transactions();
    let rows = db[table]; if (!rows) throw new DemoError(`relation "${table}" does not exist`);
    if (!u) return [];
    if (PROMOTER_SCOPED[table]) rows = rows.filter((r) => E.canSee(r[PROMOTER_SCOPED[table]]));
    if (table === 'app_users') rows = rows.filter((r) => r.id === u.id || u.role === 'admin' || (u.role === 'supervisor' && r.role === 'promoter' && E.canSee(r.id)));
    if (table === 'activity_flags') rows = rows.filter((r) => u.role === 'admin' || (u.role === 'supervisor' && r.promoter_id && E.canSee(r.promoter_id)));
    if (['audit_logs', 'prize_pools', 'sale_validations', 'consumers'].includes(table) && u.role !== 'admin') rows = [];
    if (['prize_configs', 'prize_config_items'].includes(table) && u.role === 'promoter') rows = [];
    return rows;
  }
  function transactions() {
    const camp = Object.fromEntries(E.db.campaigns.map((c) => [c.id, c.code]));
    const out = [];
    for (const s of E.db.sales.filter((x) => E.canSee(x.promoter_id))) {
      const sp = E.db.spins.filter((x) => x.sale_id === s.id);
      const base = { transaction_id: s.id, campaign_code: camp[s.campaign_id], campaign_id: s.campaign_id, date: s.biz_date, state: s.state_name, territory: s.territory_name,
        tse_id: s.tse_id, tse_code: s.tse_code, tse_name: s.tse_name, outlet_id: s.outlet_id, outlet_code: s.outlet_code, outlet_name: s.outlet_name, area: s.outlet_area,
        city: s.outlet_city, distributor: s.distributor, promoter_id: s.promoter_id, promoter_code: s.promoter_code, promoter_name: s.promoter_name,
        promoter_type: s.promoter_type, sku_code: s.sku_code, sku: s.product_name, quantity: s.quantity, sale_status: s.status, state_id: s.state_id,
        territory_id: s.territory_id, product_id: s.product_id };
      if (!sp.length) out.push({ ...base, spin_id: null, time: null, device_ref: s.device_ref, spun_at: null });
      for (const x of sp) out.push({ ...base, spin_id: x.spin_code, time: new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(new Date(x.created_at)),
        prize_id: x.prize_id, prize_name: x.prize_name, prize_cost: x.prize_cost, substituted: x.substituted, redemption_status: x.redemption_status,
        inventory_status: x.inventory_status, handed_over_at: x.handed_over_at, device_ref: x.device_ref || s.device_ref, config_version: x.config_version, spun_at: x.created_at });
    }
    return out;
  }
  function embed(table, rows, cols) {
    if (table === 'prize_config_items' && /prize_configs/.test(cols)) return rows.map((r) => ({ ...r, prize_configs: E.db.prize_configs.find((c) => c.id === r.config_id) }));
    if (table === 'prize_configs' && /prize_config_items/.test(cols)) return rows.map((r) => ({ ...r, prize_config_items: E.db.prize_config_items.filter((i) => i.config_id === r.id) }));
    return rows;
  }

  class Query {
    constructor(table) { this.table = table; this.op = 'select'; this.cols = '*'; this.filters = []; this.orders = []; this.rng = null; this.lim = null; this.one = null; this.payload = null; this.ret = false; }
    select(cols = '*') { if (this.op === 'select') this.cols = cols; else this.ret = true; return this; }
    eq(k, v) { this.filters.push((r) => getPath(r, k) === v || (getPath(r, k) != null && v != null && String(getPath(r, k)) === String(v))); return this; }
    gte(k, v) { this.filters.push((r) => getPath(r, k) >= v); return this; }
    lte(k, v) { this.filters.push((r) => getPath(r, k) <= v); return this; }
    or(expr) {
      const parts = expr.split(',').map((p) => { const i = p.lastIndexOf('.eq.'); return [p.slice(0, i), p.slice(i + 4)]; });
      this.filters.push((r) => parts.some(([k, v]) => String(getPath(r, k) ?? '') === v)); return this;
    }
    order(k, { ascending = true } = {}) { this.orders.push([k, ascending]); return this; }
    range(a, b) { this.rng = [a, b]; return this; }
    limit(n) { this.lim = n; return this; }
    maybeSingle() { this.one = 'maybe'; return this; }
    single() { this.one = 'single'; return this; }
    insert(rows) { this.op = 'insert'; this.payload = Array.isArray(rows) ? rows : [rows]; return this; }
    update(patch) { this.op = 'update'; this.payload = patch; return this; }
    delete() { this.op = 'delete'; return this; }
    then(res, rej) { return wait(null).then(() => this.exec()).then(res, rej); }
    exec() {
      setUid();
      try {
        const u = E.me();
        if (this.op !== 'select') {
          if (!u || !MASTER.has(this.table) || u.role !== 'admin') throw new DemoError(`permission denied for table ${this.table}`);
          const tbl = E.db[this.table]; const ts = new Date().toISOString(); let out = [];
          if (this.op === 'insert') {
            for (const r of this.payload) {
              const row = { ...(this.table.startsWith('campaign_') ? {} : { id: crypto.randomUUID(), created_at: ts, updated_at: ts }),
                ...(['states', 'territories', 'tses', 'outlets'].includes(this.table) ? { status: 'active', external_ref: null } : {}),
                ...(this.table === 'outlets' ? { source: 'master' } : {}), ...r };
              for (const k of ['code', 'outlet_code', 'sku_code']) if (row[k] && tbl.some((x) => x[k] === row[k])) throw new DemoError(`duplicate key value violates unique constraint (${k})`);
              tbl.push(row); out.push(row);
              E.audit('MASTER_INSERT', this.table, row.id || null, { new: row });
            }
          } else {
            const hit = tbl.filter((r) => this.filters.every((f) => f(r)));
            if (this.op === 'update') hit.forEach((r) => { Object.assign(r, this.payload, r.updated_at !== undefined ? { updated_at: ts } : {}); E.audit('MASTER_UPDATE', this.table, r.id || r.user_id, { changed: this.payload }); });
            else { E.db[this.table] = tbl.filter((r) => !hit.includes(r)); }
            out = hit;
          }
          E.save();
          const data = this.ret ? (this.one ? clone(out[0]) : clone(out)) : null;
          return { data, error: null };
        }
        let rows = visibleRows(this.table).filter((r) => true);
        rows = embed(this.table, rows, this.cols).filter((r) => this.filters.every((f) => f(r)));
        for (const [k, asc] of [...this.orders].reverse()) {
          rows = [...rows].sort((a, b) => { const x = getPath(a, k); const y = getPath(b, k); if (x == null && y == null) return 0; if (x == null) return 1; if (y == null) return -1; return (x < y ? -1 : x > y ? 1 : 0) * (asc ? 1 : -1); });
        }
        if (this.rng) rows = rows.slice(this.rng[0], this.rng[1] + 1);
        if (this.lim != null) rows = rows.slice(0, this.lim);
        if (this.one) {
          if (this.one === 'single' && rows.length !== 1) return { data: null, error: { message: 'JSON object requested, multiple (or no) rows returned' } };
          return { data: clone(rows[0] ?? null), error: null };
        }
        return { data: clone(rows), error: null };
      } catch (e) { return { data: null, error: { message: e.code || e.message, hint: e.hint, details: e.details } }; }
    }
  }

  const client = {
    demo: true,
    reset() { E.reset(); },
    from: (t) => new Query(t),
    async rpc(fn, args = {}) {
      await wait();
      setUid();
      if (!RPCS.has(fn)) return { data: null, error: { message: 'permission denied for function ' + fn } };
      try { const data = E[fn](args); E.save(); return { data: clone(data), error: null }; }
      catch (e) { E.load(); return { data: null, error: { message: e.code || e.message, hint: e.hint, details: e.details } }; }
    },
    auth: {
      async getSession() { return { data: { session: readSession() } }; },
      onAuthStateChange(cb) { listeners.add(cb); return { data: { subscription: { unsubscribe: () => listeners.delete(cb) } } }; },
      async signInWithPassword({ email, password }) {
        await wait(); E.load();
        const login = String(email).split('@')[0];
        const a = E.db._auth.find((x) => x.email === login && x.password === password);
        const u = a && E.db.app_users.find((x) => x.id === a.id);
        if (!a || !u || !u.is_active) return { data: {}, error: { message: 'Invalid login credentials' } };
        const s = { access_token: 'demo', user: { id: a.id, email } };
        localStorage.setItem(SKEY, JSON.stringify(s)); emit('SIGNED_IN', s);
        return { data: { session: s }, error: null };
      },
      async signOut() { localStorage.removeItem(SKEY); emit('SIGNED_OUT', null); return { error: null }; },
    },
    functions: {
      async invoke(name, { body }) {
        await wait(); setUid();
        const u = E.me(); if (!u || u.role !== 'admin') return { data: null, error: { message: 'Admin only' } };
        const db = E.db;
        try {
          if (body.action === 'create') {
            const login = String(body.login_id).trim().toLowerCase();
            if (db._auth.some((x) => x.email === login)) throw new Error('That login ID already exists');
            if (!body.pin || body.pin.length < 6) throw new Error('PIN must be at least 6 characters');
            const id = crypto.randomUUID(); const ts = new Date().toISOString();
            db._auth.push({ id, email: login, password: body.pin });
            db.app_users.push({ id, role: body.role, login_id: login, full_name: body.full_name, mobile: body.mobile, email: null, is_active: true,
              can_approve_outlets: !!body.can_approve_outlets, can_override_cost_target: !!body.can_override_cost_target, created_at: ts, updated_at: ts });
            if (body.role === 'promoter') db.promoters.push({ user_id: id, ...body.promoter, joined_on: null, notes: null, created_at: ts, updated_at: ts });
            E.audit('USER_CREATED', 'app_users', id, { role: body.role, login_id: login });
          } else if (body.action === 'reset_pin') {
            const a = db._auth.find((x) => x.id === body.user_id); if (!a) throw new Error('User not found'); a.password = String(body.pin);
            E.audit('USER_PIN_RESET', 'app_users', body.user_id, {});
          } else if (body.action === 'set_active') {
            const t = db.app_users.find((x) => x.id === body.user_id); if (body.user_id === u.id && !body.active) throw new Error('You cannot disable yourself');
            t.is_active = !!body.active; E.audit(body.active ? 'USER_ENABLED' : 'USER_DISABLED', 'app_users', body.user_id, {});
          } else throw new Error('Unknown action');
          E.save(); return { data: { ok: true }, error: null };
        } catch (e) { return { data: { error: e.message }, error: null }; }
      },
    },
    storage: {
      from() {
        return {
          async upload(path, file) {
            const url = await new Promise((r) => { const fr = new FileReader(); fr.onload = () => r(fr.result); fr.readAsDataURL(file); });
            E.load(); E.db._storage[path] = url; E.save(); return { data: { path }, error: null };
          },
          getPublicUrl(path) { return { data: { publicUrl: E.db._storage[path] } }; },
        };
      },
    },
  };
  return client;
}
