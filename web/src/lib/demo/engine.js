// DEMO MODE ENGINE — a JavaScript port of the Supabase SQL functions, running in the browser.
// For walkthroughs/testing only: in production the prize draw runs on the server (see supabase/migrations).
import { seedDb, U } from './seed.js';

const KEY = 'rio.demo.db';
export class DemoError extends Error { constructor(code, hint, detail) { super(code); this.code = code; this.hint = hint; this.details = detail; } }
const fail = (code, hint, detail) => { throw new DemoError(code, hint, detail); };

export function istDate(d = new Date()) { return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata' }).format(d); }
function istHM(d = new Date()) { return new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', hour12: false }).format(d); }
const uuid = () => crypto.randomUUID();
const rnd = () => crypto.getRandomValues(new Uint32Array(1))[0] / 2 ** 32;
const r2 = (n) => Math.round(n * 100) / 100;
function hash(s) { let h1 = 0x811c9dc5, h2 = 0x1000193; for (let i = 0; i < s.length; i++) { h1 = Math.imul(h1 ^ s.charCodeAt(i), 16777619); h2 = Math.imul(h2 + s.charCodeAt(i), 2246822519); } return (h1 >>> 0).toString(16).padStart(8, '0') + (h2 >>> 0).toString(16).padStart(8, '0'); }

export class Engine {
  constructor() { this.load(); this.clock = null; this.uid = null; }
  load() {
    try { this.db = JSON.parse(localStorage.getItem(KEY)); } catch { this.db = null; }
    if (!this.db || !this.db.states) { this.db = seedDb(); this.save(); this.generateHistory(); }
  }
  save() { try { localStorage.setItem(KEY, JSON.stringify(this.db)); } catch { /* quota */ } }
  reset() { try { localStorage.removeItem(KEY); } catch { /* */ } this.load(); }
  now() { return this.clock ? new Date(this.clock) : new Date(); }
  t(name) { return this.db[name]; }
  me() { return this.t('app_users').find((u) => u.id === this.uid); }

  // ---------- identity ----------
  requireUser() { const u = this.me(); if (!u) fail('NOT_AUTHENTICATED'); if (!u.is_active) fail('USER_DISABLED', 'Your account has been disabled.'); return u; }
  requirePromoter() { const u = this.requireUser(); if (u.role !== 'promoter') fail('PROMOTER_ONLY'); return u; }
  requireStaff() { const u = this.requireUser(); if (!['admin', 'supervisor'].includes(u.role)) fail('STAFF_ONLY'); return u; }
  requireAdmin() { const u = this.requireStaff(); if (u.role !== 'admin') fail('ADMIN_ONLY'); return u; }
  canSee(pid) {
    const u = this.me(); if (!u || !u.is_active) return false;
    if (u.role === 'admin') return true;
    if (u.role === 'promoter') return pid === u.id;
    return this.t('promoters').some((p) => p.user_id === pid && p.supervisor_id === u.id);
  }

  // ---------- audit ----------
  audit(action, entity, entity_id, details = {}) {
    const logs = this.t('audit_logs'); const prev = logs.length ? logs[logs.length - 1].hash : null;
    const at = this.now().toISOString(); const u = this.me();
    const row = { id: logs.length + 1, at, actor_id: this.uid, actor_role: u?.role || 'system', action, entity, entity_id: entity_id == null ? null : String(entity_id), details, prev_hash: prev };
    row.hash = hash([prev || 'GENESIS', at, row.actor_id || 'system', action, entity || '', row.entity_id || '', JSON.stringify(details)].join('|'));
    logs.push(row);
  }
  verify_audit_chain() {
    this.requireAdmin(); let prev = null; let n = 0;
    for (const r of this.t('audit_logs')) {
      n++;
      const h = hash([r.prev_hash || 'GENESIS', r.at, r.actor_id || 'system', r.action, r.entity || '', r.entity_id || '', JSON.stringify(r.details)].join('|'));
      if (r.prev_hash !== prev || r.hash !== h) return { intact: false, broken_at_id: r.id, checked: n };
      prev = r.hash;
    }
    return { intact: true, checked: n };
  }

  // ---------- flags ----------
  rule(cid, k, d) { const c = this.t('campaigns').find((x) => x.id === cid); return Number(c?.flag_rules?.[k] ?? d); }
  flag(pid, cid, type, severity, reason, details = {}) {
    const date = istDate(this.now()); const key = `${pid}:${type}:${date}`;
    const f = this.t('activity_flags').find((x) => x.flag_key === key);
    const ts = this.now().toISOString();
    if (f) { f.occurrences++; f.reason = reason; f.details = details; if (f.status !== 'dismissed') f.status = 'open'; f.updated_at = ts; return; }
    this.t('activity_flags').push({ id: uuid(), promoter_id: pid, campaign_id: cid, flag_type: type, severity, reason, details, flag_date: date, flag_key: key,
      occurrences: 1, source: 'system', raised_by: null, status: 'open', reviewed_by: null, reviewed_at: null, review_note: null, created_at: ts, updated_at: ts });
  }
  checkAfterSpin(s) {
    const c = this.t('campaigns').find((x) => x.id === s.campaign_id);
    const mine = this.t('spins').filter((x) => x.promoter_id === s.promoter_id && x.id !== s.id && x.created_at < s.created_at);
    const prev = mine.reduce((m, x) => (x.created_at > m ? x.created_at : m), '');
    const gap = prev ? (new Date(s.created_at) - new Date(prev)) / 1000 : null;
    if (gap != null && gap < this.rule(c.id, 'min_seconds_between_spins', 20)) this.flag(s.promoter_id, c.id, 'rapid_spins', 'medium', `Spins ${Math.round(gap)} seconds apart (minimum expected ${this.rule(c.id, 'min_seconds_between_spins', 20)} s)`, { spin_code: s.spin_code });
    const today = this.t('spins').filter((x) => x.promoter_id === s.promoter_id && x.biz_date === s.biz_date);
    if (today.length > this.rule(c.id, 'max_spins_per_day', 250)) this.flag(s.promoter_id, c.id, 'high_spin_count', 'medium', `${today.length} spins today`, {});
    const hv = today.filter((x) => x.prize_cost >= this.rule(c.id, 'high_value_cost', 100)).length;
    if (hv > this.rule(c.id, 'max_high_value_per_day', 3)) this.flag(s.promoter_id, c.id, 'high_value_concentration', 'high', `${hv} high-value prizes won today (threshold ${this.rule(c.id, 'max_high_value_per_day', 3)})`, {});
    const hm = istHM(new Date(s.created_at));
    if (hm < c.work_start.slice(0, 5) || hm > c.work_end.slice(0, 5)) this.flag(s.promoter_id, c.id, 'outside_hours', 'low', `Spin at ${hm} IST — outside working hours ${c.work_start.slice(0, 5)}–${c.work_end.slice(0, 5)}`, { spin_code: s.spin_code });
  }
  run_flag_scan() {
    const byP = {};
    for (const s of this.t('spins')) {
      if (s.redemption_status !== 'pending') continue;
      if ((this.now() - new Date(s.created_at)) / 60000 < this.rule(s.campaign_id, 'stale_pending_minutes', 30)) continue;
      (byP[s.promoter_id] ||= []).push(s);
    }
    for (const [pid, list] of Object.entries(byP)) this.flag(pid, list[0].campaign_id, 'incomplete_transactions', 'medium', `${list.length} spin(s) not marked as handed over`, {});
    return Object.keys(byP).length;
  }

  // ---------- helpers ----------
  outletCtx(outletId) {
    const o = this.t('outlets').find((x) => x.id === outletId && x.status === 'active'); if (!o) return null;
    const t = this.t('tses').find((x) => x.id === o.tse_id); const tr = this.t('territories').find((x) => x.id === t.territory_id);
    const st = this.t('states').find((x) => x.id === tr.state_id);
    return { outlet_id: o.id, outlet_code: o.outlet_code, outlet_name: o.name, area: o.area, city: o.city, distributor: o.distributor,
      tse_id: t.id, tse_code: t.code, tse_name: t.name, territory_id: tr.id, territory_name: tr.name, state_id: st.id, state_name: st.name };
  }
  resolveCampaign(pid, stateId) {
    const today = istDate(this.now());
    return this.t('campaigns').filter((c) => c.status === 'active' && (!c.start_date || c.start_date <= today) && (!c.end_date || c.end_date >= today)
      && this.t('campaign_states').some((cs) => cs.campaign_id === c.id && cs.state_id === stateId)
      && (!this.t('campaign_promoters').some((cp) => cp.campaign_id === c.id) || this.t('campaign_promoters').some((cp) => cp.campaign_id === c.id && cp.promoter_id === pid)))
      .sort((a, b) => String(b.start_date).localeCompare(String(a.start_date)))[0] || null;
  }
  activeConfig(cid, stateId) {
    const l = this.t('prize_configs').filter((p) => p.campaign_id === cid && p.is_active && (p.state_id === stateId || !p.state_id));
    return l.find((p) => p.state_id) || l[0] || null;
  }
  poolKey(scope, s) { return { promoter: s.promoter_id, outlet: s.outlet_id, territory: s.territory_id, state: s.state_id }[scope] || s.campaign_id; }
  openPool(c, key) { return this.t('prize_pools').find((p) => p.campaign_id === c.id && p.scope === c.pool_scope && p.scope_key === key && !p.exhausted_at && !p.voided_at); }
  newPool(c, cfg, key) {
    const no = this.t('prize_pools').filter((p) => p.campaign_id === c.id && p.scope === c.pool_scope && p.scope_key === key).length + 1;
    const items = this.t('prize_config_items').filter((i) => i.config_id === cfg.id && i.quantity > 0);
    const slots = []; items.forEach((i) => { for (let k = 0; k < i.quantity; k++) slots.push({ prize_id: i.prize_id, unit_cost: i.unit_cost }); });
    if (!slots.length) fail('NO_PRIZE_CONFIG');
    for (let i = slots.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [slots[i], slots[j]] = [slots[j], slots[i]]; }
    const pool = { id: uuid(), campaign_id: c.id, config_id: cfg.id, scope: c.pool_scope, scope_key: key, pool_no: no, size: slots.length, used: 0,
      created_at: this.now().toISOString(), exhausted_at: null, voided_at: null, void_reason: null };
    this.t('prize_pools').push(pool);
    slots.forEach((s, i) => this.t('prize_pool_slots').push({ pool_id: pool.id, position: i + 1, ...s, used_at: null, spin_id: null, deferred_at: null }));
    this.audit('POOL_CREATED', 'prize_pools', pool.id, { scope: c.pool_scope, pool_no: no, size: slots.length });
    return pool;
  }
  currentPool(c, cfg, key) {
    let pool = this.openPool(c, key);
    if (pool && pool.config_id !== cfg.id && c.config_change_mode === 'regenerate_now') {
      pool.voided_at = this.now().toISOString(); pool.void_reason = 'prize configuration changed';
      this.audit('POOL_VOIDED', 'prize_pools', pool.id, { reason: 'config_changed' }); pool = null;
    }
    return pool || this.newPool(c, cfg, key);
  }
  inv(pid, prize) { let i = this.t('promoter_inventory').find((x) => x.promoter_id === pid && x.prize_id === prize); if (!i) { i = { promoter_id: pid, prize_id: prize, on_hand: 0, reserved: 0, updated_at: null }; this.t('promoter_inventory').push(i); } return i; }
  avail(pid, prize) { const i = this.t('promoter_inventory').find((x) => x.promoter_id === pid && x.prize_id === prize); return i ? i.on_hand - i.reserved : 0; }
  moveStock(pid, prize, type, qty, spinId, note, ref, release = 0) {
    const i = this.inv(pid, prize); i.on_hand += qty; i.reserved -= release; i.updated_at = this.now().toISOString();
    this.t('inventory_movements').push({ id: uuid(), promoter_id: pid, prize_id: prize, movement_type: type, qty, on_hand_after: i.on_hand, spin_id: spinId,
      performed_by: this.uid, reference: ref, note, created_at: this.now().toISOString() });
    return i.on_hand;
  }
  prizeName(id) { return this.t('prizes').find((p) => p.id === id)?.short_name; }
  stockProblem(c, cfg, pid, key) {
    if (!c.track_inventory) return null;
    let pool = c.draw_strategy === 'controlled_pool' ? this.openPool(c, key) : null;
    if (pool && pool.config_id !== cfg.id && c.config_change_mode !== 'next_pool') pool = null;
    let ids = pool ? [...new Set(this.t('prize_pool_slots').filter((s) => s.pool_id === pool.id && !s.used_at).map((s) => s.prize_id))]
      : this.t('prize_config_items').filter((i) => i.config_id === cfg.id && i.quantity > 0).map((i) => i.prize_id);
    if (c.snack_launch_active) ids = ids.filter((id) => ['SNACK5', 'SNACK10'].includes(this.t('prizes').find((p) => p.id === id)?.code));
    const missing = ids.filter((id) => this.avail(pid, id) <= 0).map((id) => this.prizeName(id));
    if (c.snack_launch_active && missing.length) return missing.join(', ');
    if (c.oos_mode === 'block') return missing.length ? missing.join(', ') : null;
    return ids.some((id) => this.avail(pid, id) > 0) ? null : (missing.join(', ') || 'all prizes');
  }
  spinJson(id) {
    const s = this.t('spins').find((x) => x.id === id); const p = this.t('prizes').find((x) => x.id === s.prize_id);
    return { spin_id: s.id, spin_code: s.spin_code, sale_id: s.sale_id, spin_no: s.spin_no, redemption_status: s.redemption_status, created_at: s.created_at,
      prize: { id: p.id, code: p.code, name: s.prize_name, short_name: p.short_name, tier: s.prize_tier, wheel_label: p.wheel_label, win_title: p.win_title, win_subtitle: p.win_subtitle, image_url: p.image_url } };
  }

  // ================= PROMOTER API =================
  set_work_context({ p_outlet_id, p_device_ref }) {
    const u = this.requirePromoter(); const r = this.outletCtx(p_outlet_id); if (!r) fail('OUTLET_NOT_ACTIVE');
    const c = this.resolveCampaign(u.id, r.state_id); const date = istDate(this.now());
    let s = this.t('promoter_sessions').find((x) => x.promoter_id === u.id && x.work_date === date);
    if (!s) { s = { id: uuid(), promoter_id: u.id, work_date: date, started_at: this.now().toISOString() }; this.t('promoter_sessions').push(s); }
    Object.assign(s, { campaign_id: c?.id || null, state_id: r.state_id, territory_id: r.territory_id, tse_id: r.tse_id, outlet_id: r.outlet_id, device_ref: p_device_ref, updated_at: this.now().toISOString() });
    this.audit('OUTLET_SELECTED', 'outlets', r.outlet_id, { outlet_code: r.outlet_code });
    return { outlet: r, campaign: c && { id: c.id, code: c.code, name: c.name, sound_default: c.sound_default, spins_per_sale: c.spins_per_sale,
      max_quantity_per_sale: c.max_quantity_per_sale, validation_rules: c.validation_rules, capture_consumer: c.capture_consumer } };
  }

  record_sale({ p_sale_id, p_outlet_id, p_product_id, p_quantity, p_device_ref, p_validation = {}, p_client_time }) {
    const u = this.requirePromoter();
    const ex = this.t('sales').find((s) => s.id === p_sale_id);
    if (ex) { if (ex.promoter_id !== u.id) fail('SALE_NOT_FOUND'); return { sale_id: ex.id, status: ex.status, spins_allowed: ex.spins_allowed, spins_used: ex.spins_used, replayed: true }; }
    if (this.t('spins').some((s) => s.promoter_id === u.id && s.redemption_status === 'pending')) fail('PENDING_HANDOVER', 'Hand over the previous prize before starting a new sale.');
    const pr = this.t('promoters').find((p) => p.user_id === u.id); if (!pr) fail('PROMOTER_PROFILE_MISSING');
    const r = this.outletCtx(p_outlet_id); if (!r) fail('OUTLET_NOT_ACTIVE');
    const c = this.resolveCampaign(u.id, r.state_id); if (!c) fail('NO_ACTIVE_CAMPAIGN', "No active campaign covers this outlet's state.");
    const p = this.t('products').find((x) => x.id === p_product_id && x.is_active); if (!p) fail('PRODUCT_NOT_ALLOWED');
    if (p.state_id && p.state_id !== r.state_id) fail('PRODUCT_NOT_ALLOWED', 'This SKU is not available in the selected region.');
    const cps = this.t('campaign_products').filter((x) => x.campaign_id === c.id);
    if (cps.length && !cps.some((x) => x.product_id === p.id)) fail('PRODUCT_NOT_ALLOWED', 'This SKU is not part of the campaign.');
    if (!p_quantity || p_quantity < 1 || p_quantity > c.max_quantity_per_sale) fail('INVALID_QUANTITY', `Quantity must be 1–${c.max_quantity_per_sale}`);
    for (const [k, v] of Object.entries(c.validation_rules || {})) if (v === 'required' && !String(p_validation?.[k] || '').trim()) fail('VALIDATION_REQUIRED', `${k.replace(/_/g, ' ')} is required`, k);
    if (c.enforce_budget) {
      const used = this.t('spins').filter((s) => s.campaign_id === c.id && s.redemption_status !== 'not_redeemed');
      if (c.total_budget && used.reduce((a, s) => a + s.prize_cost, 0) >= c.total_budget) fail('BUDGET_EXHAUSTED', 'Campaign budget fully used.');
      if (c.daily_budget && used.filter((s) => s.biz_date === istDate(this.now())).reduce((a, s) => a + s.prize_cost, 0) >= c.daily_budget) fail('BUDGET_EXHAUSTED', "Today's budget fully used.");
    }
    const cfg = this.activeConfig(c.id, r.state_id); if (!cfg) fail('NO_PRIZE_CONFIG', 'Admin has not configured prizes for this campaign/state.');
    const key = this.poolKey(c.pool_scope, { promoter_id: u.id, outlet_id: r.outlet_id, territory_id: r.territory_id, state_id: r.state_id, campaign_id: c.id });
    const prob = this.stockProblem(c, cfg, u.id, key); if (prob) fail('OUT_OF_STOCK', 'Replenish prize stock: ' + prob, prob);
    this.t('sales').filter((s) => s.promoter_id === u.id && s.status === 'open' && s.spins_used === 0).forEach((s) => { s.status = 'cancelled'; s.cancelled_reason = 'superseded by new sale'; });
    this.t('sales').push({ id: p_sale_id, campaign_id: c.id, biz_date: istDate(this.now()), created_at: this.now().toISOString(), client_created_at: p_client_time || null,
      promoter_id: u.id, promoter_code: pr.promoter_code, promoter_name: u.full_name, promoter_type: pr.promoter_type,
      state_id: r.state_id, state_name: r.state_name, territory_id: r.territory_id, territory_name: r.territory_name, tse_id: r.tse_id, tse_code: r.tse_code, tse_name: r.tse_name,
      outlet_id: r.outlet_id, outlet_code: r.outlet_code, outlet_name: r.outlet_name, outlet_area: r.area, outlet_city: r.city, distributor: r.distributor,
      product_id: p.id, sku_code: p.sku_code, product_name: p.name, quantity: p_quantity, spins_allowed: c.spins_per_sale, spins_used: 0, status: 'open',
      cancelled_reason: null, validation: p_validation || {}, consumer_id: null, device_ref: p_device_ref || null, session_ref: null });
    this.audit('SALE_RECORDED', 'sales', p_sale_id, { outlet_code: r.outlet_code, sku: p.sku_code, qty: p_quantity });
    return { sale_id: p_sale_id, status: 'open', spins_allowed: c.spins_per_sale, spins_used: 0, replayed: false };
  }

  capture_sale_customer({ p_sale_id, p_name, p_phone }) {
    const u = this.requirePromoter();
    const sale = this.t('sales').find((x) => x.id === p_sale_id && x.promoter_id === u.id);
    if (!sale) fail('SALE_NOT_FOUND');
    if (!String(p_name || '').trim()) fail('CUSTOMER_NAME_REQUIRED');
    if (sale.status !== 'open' || this.t('spins').some((x) => x.sale_id === sale.id)) fail('SALE_ALREADY_SPUN');
    let consumer = this.t('consumers').find((x) => x.id === sale.consumer_id);
    if (!consumer) { consumer = { id: uuid(), consent: false, created_at: this.now().toISOString() }; this.t('consumers').push(consumer); sale.consumer_id = consumer.id; }
    consumer.name = String(p_name).trim(); consumer.mobile = String(p_phone || '').trim() || null;
    this.audit('CUSTOMER_CAPTURED', 'sales', sale.id, { phone_provided: !!consumer.mobile });
    return { ok: true };
  }

  getAllocation(c, key) {
    let list = this.t('campaign_allocations');
    if (!list) { list = []; this.db.campaign_allocations = list; }
    let alloc = list.find((a) => a.campaign_id === c.id && a.scope === c.pool_scope && a.scope_key === key);
    if (!alloc) {
      const salesById = new Map(this.t('sales').map((s) => [s.id, s]));
      const launchLedger = key.endsWith(':snack-launch');
      const existingSpins = this.t('spins').filter((sp) => {
        if (sp.campaign_id !== c.id || sp.redemption_status === 'not_redeemed') return false;
        if (launchLedger ? sp.allocation_phase !== 'snack_launch' : sp.allocation_phase === 'snack_launch') return false;
        const sale = salesById.get(sp.sale_id);
        return c.pool_scope === 'campaign' || (c.pool_scope === 'promoter' && sp.promoter_id === key)
          || (c.pool_scope === 'outlet' && sale?.outlet_id === key)
          || (c.pool_scope === 'territory' && sale?.territory_id === key)
          || (c.pool_scope === 'state' && sale?.state_id === key);
      });
      const awarded = {};
      for (const sp of existingSpins) awarded[sp.prize_id] = (awarded[sp.prize_id] || 0) + 1;
      alloc = {
        id: uuid(),
        campaign_id: c.id,
        scope: c.pool_scope,
        scope_key: key,
        total_spins: existingSpins.length,
        awarded,
        created_at: this.now().toISOString(),
        updated_at: this.now().toISOString(),
      };
      list.push(alloc);
    }
    return alloc;
  }

  drawCumulativePrize(c, cfg, promoterId, key) {
    const launch = !!c.snack_launch_active;
    const alloc = this.getAllocation(c, launch ? `${key}:snack-launch` : key);
    const n = alloc.total_spins + 1;
    const allItems = this.t('prize_config_items').filter((i) => i.config_id === cfg.id);
    const items = launch ? allItems.filter((i) => ['SNACK5', 'SNACK10'].includes(this.t('prizes').find((p) => p.id === i.prize_id)?.code)) : allItems;
    if (launch && c.track_inventory && items.some((i) => this.avail(promoterId, i.prize_id) <= 0)) fail('OUT_OF_STOCK', 'Both snack prizes must be in stock during the temporary 85/15 launch phase.');
    const refSize = cfg.pool_size || 200;

    if (c.track_inventory && c.oos_mode === 'block'
      && items.some((item) => Number(item.percentage ?? (Number(item.quantity) / refSize * 100)) > 0
        && this.avail(promoterId, item.prize_id) <= 0)) {
      fail('OUT_OF_STOCK', 'Prize stock is temporarily unavailable. Please contact the supervisor.');
    }

    const candidates = [];
    let eligibleCount = 0;
    let totalWeight = 0;
    let bestDeficit = -999999;
    let bestPrize = null;
    let bestCost = null;

    for (const it of items) {
      const code = this.t('prizes').find((p) => p.id === it.prize_id)?.code;
      const pct = launch ? (code === 'SNACK5' ? 85 : 15) : (it.percentage != null && it.percentage > 0 ? Number(it.percentage) : (Number(it.quantity) / refSize) * 100);
      if (pct <= 0) continue;
      const stock = c.track_inventory ? this.avail(promoterId, it.prize_id) : 99999;
      const actual = Number(alloc.awarded[it.prize_id] || 0);
      const target = (n * pct) / 100;
      const deficit = target - actual;

      if (stock > 0) {
        eligibleCount++;
        if (deficit > bestDeficit) {
          bestDeficit = deficit;
          bestPrize = it.prize_id;
          bestCost = it.unit_cost;
        }

        candidates.push({ prize_id: it.prize_id, unit_cost: it.unit_cost, pct, deficit });
      }
    }

    if (eligibleCount === 0) fail('OUT_OF_STOCK', 'All configured prizes are currently out of stock with promoter.');

    // Randomise among the near-largest deficits. Restricting the pool to a
    // 1.5-prize window keeps cumulative rounding error bounded.
    const maxDeficit = Math.max(...candidates.map((candidate) => candidate.deficit));
    for (const candidate of candidates) {
      candidate.isConstrained = candidate.deficit < maxDeficit - 1.5;
      candidate.weight = (candidate.pct / 100) * Math.exp(Math.max(-4, Math.min(0, (candidate.deficit - maxDeficit) / 0.75)));
      if (!candidate.isConstrained) totalWeight += candidate.weight;
    }

    if (totalWeight <= 0) {
      candidates.forEach((cd) => { cd.isConstrained = false; });
      totalWeight = candidates.reduce((sum, cd) => sum + cd.weight, 0);
    }

    let wonPrize = null;
    let wonCost = null;

    if (totalWeight <= 0) {
      wonPrize = bestPrize;
      wonCost = bestCost;
    } else {
      let r = rnd() * totalWeight;
      const active = candidates.filter((cd) => !cd.isConstrained);
      for (const cd of active) {
        r -= cd.weight;
        if (r <= 0) {
          wonPrize = cd.prize_id;
          wonCost = cd.unit_cost;
          break;
        }
      }
      if (!wonPrize && active.length > 0) {
        wonPrize = active[active.length - 1].prize_id;
        wonCost = active[active.length - 1].unit_cost;
      }
    }

    if (c.track_inventory) {
      const inv = this.inv(promoterId, wonPrize);
      if (inv.on_hand - inv.reserved <= 0) fail('OUT_OF_STOCK', 'Selected prize stock changed before reservation.');
      inv.reserved++;
    }
    alloc.total_spins = n;
    alloc.awarded[wonPrize] = (alloc.awarded[wonPrize] || 0) + 1;
    alloc.updated_at = this.now().toISOString();

    return { prize_id: wonPrize, unit_cost: wonCost, total_spins: n };
  }

  play_spin({ p_sale_id, p_spin_no = 1, p_device_ref }) {
    const u = this.requirePromoter();
    const s = this.t('sales').find((x) => x.id === p_sale_id); if (!s || s.promoter_id !== u.id) fail('SALE_NOT_FOUND');
    const ex = this.t('spins').find((x) => x.sale_id === s.id && x.spin_no === p_spin_no);
    if (ex) return { ...this.spinJson(ex.id), replayed: true };
    if (s.status === 'cancelled') fail('SALE_CANCELLED');
    if (p_spin_no !== s.spins_used + 1 || p_spin_no > s.spins_allowed) fail('NO_SPINS_LEFT', 'This sale has already used its spin.');
    const c = this.t('campaigns').find((x) => x.id === s.campaign_id); if (c.status !== 'active') fail('CAMPAIGN_NOT_ACTIVE');
    const cfg = this.activeConfig(c.id, s.state_id); if (!cfg) fail('NO_PRIZE_CONFIG');
    const key = this.poolKey(c.pool_scope, s); const spinId = uuid();

    const drawn = this.drawCumulativePrize(c, cfg, u.id, key);
    const prize = drawn.prize_id;
    const cost = drawn.unit_cost;

    const pz = this.t('prizes').find((x) => x.id === prize);
    this.db._seq++;
    const d = this.now();
    const row = { id: spinId, spin_code: `SPN${istDate(d).slice(2).replace(/-/g, '')}-${String(this.db._seq).padStart(6, '0')}`, sale_id: s.id, spin_no: p_spin_no,
      campaign_id: c.id, promoter_id: u.id, biz_date: istDate(d), created_at: d.toISOString(), strategy: c.draw_strategy, pool_id: null,
      slot_position: null, config_id: cfg.id, config_version: cfg.version, prize_id: pz.id, prize_code: pz.code, prize_name: pz.name,
      prize_tier: pz.tier, prize_cost: Number(cost), original_prize_id: null, substituted: false, redemption_status: 'pending', handed_over_at: null,
      inventory_status: c.track_inventory ? 'reserved' : 'not_tracked', allocation_phase: c.snack_launch_active ? 'snack_launch' : 'standard',
      resolved_by: null, resolution_note: null, device_ref: p_device_ref || s.device_ref };
    this.t('spins').push(row);
    s.spins_used++; s.status = 'spun';
    this.audit('SPIN', 'spins', spinId, { sale_id: s.id, prize: pz.code, cost: Number(cost), config_version: cfg.version, cumulative_spins: drawn.total_spins });
    this.checkAfterSpin(row);
    return { ...this.spinJson(spinId), replayed: false };
  }

  confirm_handover({ p_spin_id }) {
    const u = this.requirePromoter();
    const sp = this.t('spins').find((x) => x.id === p_spin_id); if (!sp || sp.promoter_id !== u.id) fail('SPIN_NOT_FOUND');
    if (sp.redemption_status === 'handed_over') return { ok: true, replayed: true };
    if (sp.redemption_status !== 'pending') fail('SPIN_ALREADY_RESOLVED');
    let left = null;
    if (sp.inventory_status === 'reserved') left = this.moveStock(u.id, sp.prize_id, 'award', -1, sp.id, 'Prize handed over ' + sp.spin_code, sp.spin_code, 1);
    sp.redemption_status = 'handed_over'; sp.handed_over_at = this.now().toISOString(); if (sp.inventory_status === 'reserved') sp.inventory_status = 'deducted';
    const sale = this.t('sales').find((x) => x.id === sp.sale_id);
    if (sale.spins_used >= sale.spins_allowed && !this.t('spins').some((x) => x.sale_id === sale.id && x.redemption_status === 'pending')) sale.status = 'completed';
    this.audit('PRIZE_HANDED_OVER', 'spins', sp.id, { spin_code: sp.spin_code, prize: sp.prize_code, on_hand_after: left });
    const p = this.t('prizes').find((x) => x.id === sp.prize_id);
    return { ok: true, replayed: false, prize_left: left, low_stock: left != null && left <= p.low_stock_threshold, prize_short_name: p.short_name };
  }

  my_pending_spin() { const s = this.t('spins').filter((x) => x.promoter_id === this.uid && x.redemption_status === 'pending').sort((a, b) => a.created_at.localeCompare(b.created_at))[0]; return s ? this.spinJson(s.id) : null; }

  cancel_open_sale({ p_sale_id, p_reason }) {
    const u = this.requirePromoter(); const s = this.t('sales').find((x) => x.id === p_sale_id);
    if (!s || s.promoter_id !== u.id) fail('SALE_NOT_FOUND');
    if (s.spins_used > 0) fail('SALE_ALREADY_SPUN', 'A spin result is permanent and cannot be cancelled.');
    s.status = 'cancelled'; s.cancelled_reason = p_reason || 'cancelled';
    this.audit('SALE_CANCELLED', 'sales', s.id, { reason: p_reason });
    const n = this.t('sales').filter((x) => x.promoter_id === u.id && x.biz_date === istDate(this.now()) && x.status === 'cancelled').length;
    if (n > this.rule(s.campaign_id, 'max_cancelled_per_day', 5)) this.flag(u.id, s.campaign_id, 'excess_cancellations', 'medium', `${n} cancelled/incomplete sales today`, {});
    return { ok: true };
  }

  get_promoter_home() {
    const u = this.requirePromoter(); const pr = this.t('promoters').find((p) => p.user_id === u.id); const today = istDate(this.now());
    const sales = this.t('sales').filter((s) => s.promoter_id === u.id && s.biz_date === today && s.status !== 'cancelled');
    const spins = this.t('spins').filter((s) => s.promoter_id === u.id && s.biz_date === today);
    const sess = this.t('promoter_sessions').find((s) => s.promoter_id === u.id && s.work_date === today);
    return {
      user: { id: u.id, name: u.full_name, login_id: u.login_id, promoter_code: pr?.promoter_code, promoter_type: pr?.promoter_type },
      today: { sales: sales.length, units: sales.reduce((a, s) => a + s.quantity, 0), spins: spins.length, prizes_given: spins.filter((s) => s.redemption_status === 'handed_over').length },
      stock: this.t('prizes').filter((p) => p.is_active).sort((a, b) => a.sort_order - b.sort_order).map((p) => {
        const i = this.t('promoter_inventory').find((x) => x.promoter_id === u.id && x.prize_id === p.id) || { on_hand: 0, reserved: 0 };
        return { prize_id: p.id, name: p.name, short_name: p.short_name, tier: p.tier, on_hand: i.on_hand, reserved: i.reserved, threshold: p.low_stock_threshold, low: i.on_hand <= p.low_stock_threshold };
      }),
      session: sess || null, pending_spin: this.my_pending_spin(), biz_date: today,
    };
  }

  submit_outlet_request({ p_name, p_area, p_city, p_ref_code, p_suggested_tse, p_note }) {
    const u = this.requirePromoter(); if (!String(p_name || '').trim()) fail('OUTLET_NAME_REQUIRED');
    const sess = this.t('promoter_sessions').find((s) => s.promoter_id === u.id && s.work_date === istDate(this.now()));
    const id = uuid();
    this.t('outlet_requests').push({ id, promoter_id: u.id, campaign_id: sess?.campaign_id || null, outlet_name: p_name.trim(), area: p_area, city: p_city, ref_code: p_ref_code,
      suggested_tse_id: p_suggested_tse, note: p_note, status: 'pending', reviewed_by: null, reviewed_at: null, review_note: null, outlet_id: null, created_at: this.now().toISOString() });
    this.audit('OUTLET_REQUESTED', 'outlet_requests', id, { name: p_name });
    const n = this.t('outlet_requests').filter((r) => r.promoter_id === u.id && istDate(new Date(r.created_at)) === istDate(this.now())).length;
    if (n > this.rule(sess?.campaign_id, 'max_outlet_requests_per_day', 3)) this.flag(u.id, sess?.campaign_id, 'repeated_outlet_not_listed', 'medium', `${n} "Outlet Not Listed" requests today`, {});
    return { request_id: id, status: 'pending' };
  }

  // ================= STAFF API =================
  adjust_stock({ p_promoter, p_prize, p_type, p_qty, p_note, p_reference }) {
    const u = this.requireStaff(); if (!this.canSee(p_promoter)) fail('NOT_YOUR_PROMOTER');
    if (p_type === 'award') fail('INVALID_MOVEMENT'); if (p_type === 'adjustment' && u.role !== 'admin') fail('ADMIN_ONLY');
    if (!p_qty || (p_type !== 'adjustment' && p_qty < 0)) fail('INVALID_QUANTITY');
    const delta = p_type === 'issue' || p_type === 'adjustment' ? p_qty : -p_qty; const i = this.inv(p_promoter, p_prize);
    if (i.on_hand + delta < i.reserved) fail('INSUFFICIENT_STOCK', `Promoter holds ${i.on_hand} (${i.reserved} reserved for pending prizes)`);
    const after = this.moveStock(p_promoter, p_prize, p_type, delta, null, p_note, p_reference);
    this.audit('STOCK_' + p_type.toUpperCase(), 'promoter_inventory', `${p_promoter}:${p_prize}`, { qty: delta, on_hand_after: after, note: p_note });
    if (['damaged', 'missing'].includes(p_type)) this.flag(p_promoter, null, 'stock_discrepancy', p_type === 'missing' ? 'high' : 'medium', `${p_qty} unit(s) of ${this.prizeName(p_prize)} recorded as ${p_type}`, {});
    return { ok: true, on_hand: after };
  }
  issue_stock_kit({ p_promoter, p_items, p_note }) { return p_items.filter((i) => i.qty > 0).map((i) => ({ ...this.adjust_stock({ p_promoter, p_prize: i.prize_id, p_type: 'issue', p_qty: i.qty, p_note }), prize_id: i.prize_id })); }
  resolve_spin({ p_spin_id, p_action, p_note }) {
    const u = this.requireStaff(); const sp = this.t('spins').find((x) => x.id === p_spin_id);
    if (!sp || !this.canSee(sp.promoter_id)) fail('SPIN_NOT_FOUND'); if (sp.redemption_status !== 'pending') fail('SPIN_ALREADY_RESOLVED');
    if (!String(p_note || '').trim()) fail('NOTE_REQUIRED');
    if (p_action === 'handed_over') {
      if (sp.inventory_status === 'reserved') { this.moveStock(sp.promoter_id, sp.prize_id, 'award', -1, sp.id, 'Resolved by supervisor: ' + p_note, sp.spin_code, 1); sp.inventory_status = 'deducted'; }
      sp.redemption_status = 'handed_over'; sp.handed_over_at = this.now().toISOString();
    } else if (p_action === 'not_redeemed') {
      if (sp.inventory_status === 'reserved') { this.inv(sp.promoter_id, sp.prize_id).reserved--; sp.inventory_status = 'released'; }
      sp.redemption_status = 'not_redeemed';
    } else fail('INVALID_ACTION');
    sp.resolved_by = u.id; sp.resolution_note = p_note;
    const sale = this.t('sales').find((x) => x.id === sp.sale_id); sale.status = 'completed';
    this.audit('SPIN_RESOLVED', 'spins', sp.id, { action: p_action, note: p_note });
    return { ok: true };
  }
  review_outlet_request({ p_request_id, p_approve, p_tse_id, p_outlet_code, p_note, p_name, p_area, p_city, p_distributor }) {
    const u = this.requireStaff(); if (u.role === 'supervisor' && !u.can_approve_outlets) fail('NOT_AUTHORISED', 'You are not authorised to approve outlets.');
    const rq = this.t('outlet_requests').find((x) => x.id === p_request_id); if (!rq || !this.canSee(rq.promoter_id)) fail('REQUEST_NOT_FOUND');
    if (rq.status !== 'pending') fail('REQUEST_ALREADY_REVIEWED');
    let outlet = null; let code = null;
    if (p_approve) {
      const tse = p_tse_id || rq.suggested_tse_id; if (!tse) fail('TSE_REQUIRED');
      code = (p_outlet_code || rq.ref_code || '').trim() || 'NEW-' + uuid().slice(0, 6).toUpperCase();
      if (this.t('outlets').some((o) => o.outlet_code === code)) fail('OUTLET_CODE_EXISTS');
      outlet = uuid(); const ts = this.now().toISOString();
      this.t('outlets').push({ id: outlet, tse_id: tse, outlet_code: code, name: p_name || rq.outlet_name, area: p_area ?? rq.area, city: p_city ?? rq.city,
        distributor: p_distributor, status: 'active', source: 'request', latitude: null, longitude: null, external_ref: null, created_at: ts, updated_at: ts });
    }
    Object.assign(rq, { status: p_approve ? 'approved' : 'rejected', reviewed_by: u.id, reviewed_at: this.now().toISOString(), review_note: p_note, outlet_id: outlet });
    this.audit(p_approve ? 'OUTLET_REQUEST_APPROVED' : 'OUTLET_REQUEST_REJECTED', 'outlet_requests', rq.id, { outlet_code: code });
    return { ok: true, outlet_id: outlet, outlet_code: code };
  }
  review_flag({ p_flag_id, p_status, p_note }) {
    const u = this.requireStaff(); const f = this.t('activity_flags').find((x) => x.id === p_flag_id);
    if (!f || (f.promoter_id && !this.canSee(f.promoter_id))) fail('FLAG_NOT_FOUND');
    Object.assign(f, { status: p_status, reviewed_by: u.id, reviewed_at: this.now().toISOString(), review_note: p_note, updated_at: this.now().toISOString() });
    this.audit('FLAG_REVIEWED', 'activity_flags', f.id, { status: p_status, note: p_note }); return { ok: true };
  }
  raise_flag({ p_promoter, p_reason, p_severity = 'medium' }) {
    const u = this.requireStaff(); if (!this.canSee(p_promoter)) fail('NOT_YOUR_PROMOTER'); const ts = this.now().toISOString(); const id = uuid();
    this.t('activity_flags').push({ id, promoter_id: p_promoter, campaign_id: null, flag_type: 'manual', severity: p_severity, reason: p_reason, details: {}, flag_date: istDate(this.now()),
      flag_key: null, occurrences: 1, source: 'manual', raised_by: u.id, status: 'open', reviewed_by: null, reviewed_at: null, review_note: null, created_at: ts, updated_at: ts });
    this.audit('FLAG_RAISED', 'activity_flags', id, { promoter_id: p_promoter, reason: p_reason }); return { ok: true, flag_id: id };
  }

  // ---------- reporting ----------
  scopedSales(f = {}) {
    const u = this.me(); const clean = Object.fromEntries(Object.entries(f || {}).filter(([, v]) => v !== '' && v != null));
    return this.t('sales').filter((s) => s.status !== 'cancelled' && this.canSee(s.promoter_id)
      && (!clean.date_from || s.biz_date >= clean.date_from) && (!clean.date_to || s.biz_date <= clean.date_to)
      && ['campaign_id', 'state_id', 'territory_id', 'tse_id', 'outlet_id', 'promoter_id', 'product_id'].every((k) => !clean[k] || s[k] === clean[k])
      && (!clean.city || s.outlet_city === clean.city) && (!clean.distributor || s.distributor === clean.distributor) && u);
  }
  spinsBySale() { const m = {}; for (const s of this.t('spins')) (m[s.sale_id] ||= []).push(s); return m; }
  report_summary({ p_group, p_filters }) {
    this.requireStaff(); const sales = this.scopedSales(p_filters); const bySale = this.spinsBySale();
    if (p_group === 'prize') {
      const spins = sales.flatMap((s) => bySale[s.id] || []).filter((x) => x.redemption_status !== 'not_redeemed');
      const g = {}; for (const x of spins) { const r = (g[x.prize_id] ||= { key: x.prize_id, label: x.prize_name, quantity: 0, total_cost: 0, handed_over: 0, pending: 0 }); r.quantity++; r.total_cost += x.prize_cost; if (x.redemption_status === 'handed_over') r.handed_over++; if (x.redemption_status === 'pending') r.pending++; }
      return Object.values(g).map((r) => ({ ...r, unit_cost: r2(r.total_cost / r.quantity), pct: r2((100 * r.quantity) / spins.length) })).sort((a, b) => b.unit_cost - a.unit_cost);
    }
    const G = {
      state: (s) => [s.state_id, s.state_name, {}], territory: (s) => [s.territory_id, s.territory_name, { state: s.state_name }],
      tse: (s) => [s.tse_id, s.tse_name, { tse_code: s.tse_code, territory: s.territory_name, state: s.state_name }],
      outlet: (s) => [s.outlet_id, s.outlet_name, { outlet_code: s.outlet_code, area: s.outlet_area, city: s.outlet_city, tse: s.tse_name, territory: s.territory_name, distributor: s.distributor }],
      promoter: (s) => [s.promoter_id, s.promoter_name, { promoter_code: s.promoter_code, promoter_type: s.promoter_type }],
      product: (s) => [s.product_id, s.product_name, { sku_code: s.sku_code }], date: (s) => [s.biz_date, s.biz_date, {}],
      city: (s) => [s.outlet_city || '—', s.outlet_city || '—', {}], distributor: (s) => [s.distributor || '—', s.distributor || '—', {}],
    }[p_group]; if (!G) fail('INVALID_GROUP');
    const g = {};
    for (const s of sales) {
      const [key, label, extra] = G(s); const sp = bySale[s.id] || [];
      const r = (g[key] ||= { key, label, ...extra, sales: 0, units: 0, spins: 0, giveaway_cost: 0, prizes_given: 0, _o: new Set(), _p: new Set(), _st: new Set(), _tr: new Set() });
      r.sales++; r.units += s.quantity; r.spins += sp.length; r.giveaway_cost += sp.filter((x) => x.redemption_status !== 'not_redeemed').reduce((a, x) => a + x.prize_cost, 0);
      r.prizes_given += sp.filter((x) => x.redemption_status === 'handed_over').length; r._o.add(s.outlet_id); r._p.add(s.promoter_id); r._st.add(s.state_name); r._tr.add(s.territory_name);
    }
    return Object.values(g).map(({ _o, _p, _st, _tr, ...r }) => ({ ...r, ...(p_group === 'promoter' ? { state: [..._st].join(', '), territory: [..._tr].join(', ') } : {}),
      active_outlets: _o.size, promoters: _p.size, avg_cost: r.spins ? r2(r.giveaway_cost / r.spins) : null })).sort((a, b) => b.spins - a.spins);
  }
  prize_distribution_report({ p_filters }) {
    this.requireStaff();
    const sales = this.scopedSales(p_filters);
    const bySale = this.spinsBySale();
    const spins = sales.flatMap((sale) => bySale[sale.id] || []).filter((spin) => spin.redemption_status !== 'not_redeemed');
    const totalCost = spins.reduce((sum, spin) => sum + Number(spin.prize_cost || 0), 0);
    const targetCounts = {};
    for (const spin of spins) {
      const cfg = this.t('prize_configs').find((config) => config.id === spin.config_id);
      const items = this.t('prize_config_items').filter((item) => item.config_id === cfg?.id);
      for (const item of items) {
        const pct = item.percentage != null ? Number(item.percentage) : Number(item.quantity) / (cfg?.pool_size || 200) * 100;
        targetCounts[item.prize_id] = (targetCounts[item.prize_id] || 0) + pct / 100;
      }
    }
    return this.t('prizes').filter((prize) => prize.is_active).map((prize) => {
      const awarded = spins.filter((spin) => spin.prize_id === prize.id);
      const quantity = awarded.length;
      const actualPct = spins.length ? r2(quantity * 100 / spins.length) : 0;
      const targetPct = spins.length ? r2((targetCounts[prize.id] || 0) * 100 / spins.length) : 0;
      return {
        key: prize.id, label: prize.name, quantity,
        unit_cost: quantity ? r2(awarded.reduce((sum, spin) => sum + spin.prize_cost, 0) / quantity) : prize.default_cost,
        total_cost: awarded.reduce((sum, spin) => sum + spin.prize_cost, 0),
        pct: actualPct, target_pct: targetPct, variance_pct: r2(actualPct - targetPct),
        handed_over: awarded.filter((spin) => spin.redemption_status === 'handed_over').length,
        pending: awarded.filter((spin) => spin.redemption_status === 'pending').length,
        total_spins: spins.length, giveaway_cost: totalCost,
        avg_giveaway_cost: spins.length ? r2(totalCost / spins.length) : 0,
      };
    }).sort((a, b) => b.unit_cost - a.unit_cost);
  }
  dashboard_kpis({ p_filters }) {
    const u = this.requireStaff(); this.run_flag_scan(); const f = p_filters || {};
    const sales = this.scopedSales(f); const bySale = this.spinsBySale(); const spins = sales.flatMap((s) => bySale[s.id] || []);
    const counted = spins.filter((x) => x.redemption_status !== 'not_redeemed'); const cost = counted.reduce((a, x) => a + x.prize_cost, 0);
    const prizes = this.t('prizes').filter((p) => p.is_active).sort((a, b) => a.sort_order - b.sort_order);
    const inv = this.t('promoter_inventory').filter((i) => this.canSee(i.promoter_id) && (!f.promoter_id || i.promoter_id === f.promoter_id));
    const users = Object.fromEntries(this.t('app_users').map((x) => [x.id, x]));
    const today = istDate(this.now());
    const c = f.campaign_id ? this.t('campaigns').find((x) => x.id === f.campaign_id) : this.t('campaigns').find((x) => x.status === 'active');
    let budget = null;
    if (c) {
      const cs = this.t('spins').filter((x) => x.campaign_id === c.id && x.redemption_status !== 'not_redeemed'); const used = cs.reduce((a, x) => a + x.prize_cost, 0);
      const avg = cs.length ? used / cs.length : c.target_cost_per_spin;
      budget = { campaign_id: c.id, campaign: c.name, total_budget: c.total_budget, used, remaining: c.total_budget == null ? null : c.total_budget - used, daily_budget: c.daily_budget,
        used_today: cs.filter((x) => x.biz_date === today).reduce((a, x) => a + x.prize_cost, 0), avg_cost: r2(avg), target: c.target_cost_per_spin,
        est_spins_remaining: c.total_budget == null ? null : Math.floor((c.total_budget - used) / avg),
        state_budgets: this.t('campaign_states').filter((x) => x.campaign_id === c.id && x.budget).map((x) => ({ state: this.t('states').find((s) => s.id === x.state_id)?.name, budget: x.budget,
          used: cs.filter((sp) => this.t('sales').find((sa) => sa.id === sp.sale_id)?.state_id === x.state_id).reduce((a, sp) => a + sp.prize_cost, 0) })) };
    }
    return {
      totals: { sales: sales.length, units: sales.reduce((a, s) => a + s.quantity, 0), spins: spins.length, giveaway_cost: cost, avg_cost: spins.length ? r2(cost / spins.length) : null,
        prizes_given: spins.filter((x) => x.redemption_status === 'handed_over').length, active_promoters: new Set(sales.map((s) => s.promoter_id)).size, active_outlets: new Set(sales.map((s) => s.outlet_id)).size },
      prizes: prizes.map((p) => { const l = counted.filter((x) => x.prize_id === p.id); return { prize_id: p.id, name: p.name, short_name: p.short_name, tier: p.tier, count: l.length, cost: l.reduce((a, x) => a + x.prize_cost, 0) }; }),
      stock: prizes.map((p) => ({ prize_id: p.id, short_name: p.short_name, on_hand: inv.filter((i) => i.prize_id === p.id).reduce((a, i) => a + i.on_hand, 0), reserved: inv.filter((i) => i.prize_id === p.id).reduce((a, i) => a + i.reserved, 0) })),
      low_stock: this.t('promoter_inventory').filter((i) => this.canSee(i.promoter_id) && users[i.promoter_id]?.is_active && i.on_hand <= (prizes.find((p) => p.id === i.prize_id)?.low_stock_threshold ?? -1))
        .map((i) => ({ promoter_id: i.promoter_id, promoter: users[i.promoter_id].full_name, prize: this.prizeName(i.prize_id), on_hand: i.on_hand, threshold: prizes.find((p) => p.id === i.prize_id).low_stock_threshold })),
      open_flags: this.t('activity_flags').filter((x) => x.status === 'open' && (x.promoter_id ? this.canSee(x.promoter_id) : u.role === 'admin')).length,
      pending_handovers: this.t('spins').filter((x) => x.redemption_status === 'pending' && this.canSee(x.promoter_id)).length,
      promoters_on_duty: this.t('promoter_sessions').filter((x) => x.work_date === today && this.canSee(x.promoter_id)).length,
      pending_outlet_requests: this.t('outlet_requests').filter((x) => x.status === 'pending' && this.canSee(x.promoter_id)).length,
      budget, biz_date: today,
    };
  }

  // ---------- admin ----------
  save_prize_config({ p_campaign, p_state, p_pool_size, p_items, p_override, p_notes }) {
    const u = this.requireAdmin(); const c = this.t('campaigns').find((x) => x.id === p_campaign); if (!c) fail('CAMPAIGN_NOT_FOUND');
    const refSize = Number(p_pool_size) || 200;
    let totPct = 0;
    let avg = 0;
    for (const i of p_items) {
      const pct = i.percentage != null && i.percentage !== '' ? Number(i.percentage) : (Number(i.quantity) / refSize) * 100;
      if (pct < 0 || Number(i.unit_cost) < 0) fail('INVALID_ITEMS');
      totPct += pct;
      avg += (pct / 100) * Number(i.unit_cost);
    }
    if (Math.abs(totPct - 100.0) > 0.05) fail('PERCENTAGE_MISMATCH', `Prize percentages add up to ${totPct.toFixed(2)}%; they must equal 100%`);
    const total = r2(avg * refSize);
    const over = avg > c.target_cost_per_spin;
    if (over && !p_override) fail('COST_ABOVE_TARGET', `Average cost per spin ₹${avg.toFixed(2)} exceeds the ₹${c.target_cost_per_spin} campaign target.`);
    if (over && !u.can_override_cost_target) fail('OVERRIDE_NOT_AUTHORISED');
    const ver = Math.max(0, ...this.t('prize_configs').filter((x) => x.campaign_id === p_campaign).map((x) => x.version)) + 1;
    const prev = this.t('prize_configs').find((x) => x.campaign_id === p_campaign && x.is_active && (x.state_id || null) === (p_state || null)); if (prev) prev.is_active = false;
    const id = uuid();
    this.t('prize_configs').push({ id, campaign_id: p_campaign, state_id: p_state || null, version: ver, pool_size: refSize, total_cost: total, avg_cost: avg, target_cost: c.target_cost_per_spin,
      exceeds_target: over, override_by: over ? u.id : null, is_active: true, notes: p_notes, created_by: u.id, created_at: this.now().toISOString() });
    p_items.filter((i) => Number(i.percentage || i.quantity) > 0).forEach((i) => {
      const pct = i.percentage != null && i.percentage !== '' ? Number(i.percentage) : (Number(i.quantity) / refSize) * 100;
      const qty = i.quantity != null ? Number(i.quantity) : Math.round((pct / 100) * refSize);
      this.t('prize_config_items').push({ config_id: id, prize_id: i.prize_id, quantity: qty, unit_cost: Number(i.unit_cost), percentage: pct });
    });
    this.audit('PRIZE_CONFIG_SAVED', 'prize_configs', id, { version: ver, ref_pool_size: refSize, total_cost: total, avg_cost: avg, override: over });
    return { config_id: id, version: ver, total_cost: total, avg_cost: r2(avg), exceeds_target: over };
  }
  pool_status({ p_campaign }) {
    this.requireAdmin(); const P = Object.fromEntries(this.t('prizes').map((p) => [p.id, p]));
    const configs = this.t('prize_configs').filter((x) => x.campaign_id === p_campaign && x.is_active).map((pc) => ({ config_id: pc.id, version: pc.version, state_id: pc.state_id,
      state_name: this.t('states').find((s) => s.id === pc.state_id)?.name || null, pool_size: pc.pool_size, total_cost: pc.total_cost, avg_cost: r2(pc.avg_cost), target: pc.target_cost,
      exceeds_target: pc.exceeds_target, items: this.t('prize_config_items').filter((i) => i.config_id === pc.id).sort((a, b) => a.unit_cost - b.unit_cost)
        .map((i) => ({ prize_id: i.prize_id, name: P[i.prize_id].name, short_name: P[i.prize_id].short_name, tier: P[i.prize_id].tier,
          quantity: i.quantity, percentage: i.percentage != null ? i.percentage : r2((i.quantity / pc.pool_size) * 100), unit_cost: i.unit_cost })) }));

    const allSpins = this.t('spins').filter((s) => s.campaign_id === p_campaign);
    const validSpins = allSpins.filter((s) => s.redemption_status !== 'not_redeemed');
    const totalSpins = validSpins.length;
    const giveawayCost = validSpins.reduce((a, s) => a + s.prize_cost, 0);
    const avgCost = totalSpins > 0 ? r2(giveawayCost / totalSpins) : 0;

    const activeCfg = this.t('prize_configs').find((x) => x.campaign_id === p_campaign && x.is_active && !x.state_id) || this.t('prize_configs').find((x) => x.campaign_id === p_campaign && x.is_active);
    const cfgItems = activeCfg ? this.t('prize_config_items').filter((i) => i.config_id === activeCfg.id) : [];

    const actualCounts = {};
    const actualCosts = {};
    const targetCounts = {};
    for (const s of validSpins) {
      actualCounts[s.prize_id] = (actualCounts[s.prize_id] || 0) + 1;
      actualCosts[s.prize_id] = (actualCosts[s.prize_id] || 0) + s.prize_cost;
      const spinConfig = this.t('prize_configs').find((pc) => pc.id === s.config_id);
      for (const ci of this.t('prize_config_items').filter((item) => item.config_id === spinConfig?.id)) {
        const pct = ci.percentage != null ? Number(ci.percentage) : Number(ci.quantity) / (spinConfig?.pool_size || 200) * 100;
        targetCounts[ci.prize_id] = (targetCounts[ci.prize_id] || 0) + pct / 100;
      }
    }

    const distItems = cfgItems.map((ci) => {
      const p = P[ci.prize_id];
      const currentTargetPct = ci.percentage != null ? ci.percentage : (ci.quantity / activeCfg.pool_size) * 100;
      const targetCount = targetCounts[ci.prize_id] || 0;
      const targetPct = totalSpins ? r2(targetCount * 100 / totalSpins) : currentTargetPct;
      const actualCount = actualCounts[ci.prize_id] || 0;
      const actualPct = totalSpins > 0 ? r2((actualCount / totalSpins) * 100) : 0;
      return {
        prize_id: ci.prize_id,
        name: p?.name || '',
        short_name: p?.short_name || '',
        tier: p?.tier || '',
        unit_cost: ci.unit_cost,
        target_pct: r2(targetPct),
        target_count: r2(totalSpins ? targetCount : 0),
        actual_count: actualCount,
        actual_pct: actualPct,
        variance_pct: r2(actualPct - targetPct),
        total_cost: actualCosts[ci.prize_id] || 0,
      };
    }).sort((a, b) => a.unit_cost - b.unit_cost);

    const distribution = {
      total_spins: totalSpins,
      giveaway_cost: giveawayCost,
      avg_giveaway_cost: avgCost,
      target_cost: activeCfg?.target_cost || 10,
      items: distItems,
    };

    return {
      configs,
      distribution,
      pools: [],
      totals: {
        total_spins_all_pools: totalSpins,
        used: totalSpins,
        giveaway_cost: giveawayCost,
        avg_cost: avgCost,
      },
    };
  }
  import_outlets({ p_rows }) {
    this.requireAdmin(); let ins = 0, upd = 0; const errors = []; const ts = this.now().toISOString();
    p_rows.forEach((r, idx) => {
      try {
        if (!r.state || !r.territory || !r.tse_code || !r.outlet_code || !r.outlet_name) throw new Error('Missing state / territory / tse_code / outlet_code / outlet_name');
        const lc = (x) => String(x).trim().toLowerCase();
        let st = this.t('states').find((s) => lc(s.name) === lc(r.state) || lc(s.code) === lc(r.state));
        if (!st) { st = { id: uuid(), code: String(r.state).replace(/[^A-Za-z]/g, '').slice(0, 3).toUpperCase() + '-' + uuid().slice(0, 4), name: String(r.state).trim(), status: 'active', external_ref: null, created_at: ts, updated_at: ts }; this.t('states').push(st); }
        let tr = this.t('territories').find((t) => t.state_id === st.id && (lc(t.name) === lc(r.territory) || lc(t.code) === lc(r.territory)));
        if (!tr) { tr = { id: uuid(), state_id: st.id, code: String(r.territory).replace(/[^A-Za-z]/g, '').slice(0, 4).toUpperCase() + '-' + uuid().slice(0, 4), name: String(r.territory).trim(), status: 'active', external_ref: null, created_at: ts, updated_at: ts }; this.t('territories').push(tr); }
        let tse = this.t('tses').find((t) => lc(t.code) === lc(r.tse_code));
        if (!tse) { tse = { id: uuid(), territory_id: tr.id, code: String(r.tse_code).trim(), name: String(r.tse_name || r.tse_code).trim(), mobile: null, status: 'active', external_ref: null, created_at: ts, updated_at: ts }; this.t('tses').push(tse); }
        else { tse.territory_id = tr.id; if (r.tse_name) tse.name = String(r.tse_name).trim(); }
        const status = ['inactive', 'n', 'no', '0', 'closed'].includes(lc(r.status || 'active')) ? 'inactive' : 'active';
        const o = this.t('outlets').find((x) => x.outlet_code === String(r.outlet_code).trim());
        const vals = { tse_id: tse.id, name: String(r.outlet_name).trim(), area: r.area || null, city: r.city || null, distributor: r.distributor || null, status, updated_at: ts };
        if (o) { Object.assign(o, vals); upd++; } else { this.t('outlets').push({ id: uuid(), outlet_code: String(r.outlet_code).trim(), source: 'upload', latitude: null, longitude: null, external_ref: null, created_at: ts, ...vals }); ins++; }
      } catch (e) { errors.push({ row: idx + 1, error: e.message }); }
    });
    this.audit('OUTLET_MASTER_UPLOAD', 'outlets', null, { rows: p_rows.length, inserted: ins, updated: upd, errors: errors.length });
    return { rows: p_rows.length, inserted: ins, updated: upd, errors };
  }

  // ---------- demo history (last 6 days) ----------
  generateHistory() {
    const plan = [[U.p1, ['80000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000002', '80000000-0000-0000-0000-000000000003']],
      [U.p2, ['80000000-0000-0000-0000-000000000006', '80000000-0000-0000-0000-000000000008']], [U.p3, ['80000000-0000-0000-0000-000000000011', '80000000-0000-0000-0000-000000000014']]];
    const products = this.t('products').map((p) => p.id);
    try {
      for (let d = 6; d >= 1; d--) {
        for (const [pid, outlets] of plan) {
          this.uid = pid; const n = 8 + Math.floor(rnd() * 10);
          let t = Date.now() - d * 86400000; t = t - (t % 86400000) + 5.5 * 3600000; // 11:00 IST
          for (let i = 0; i < n; i++) {
            t += (60 + Math.floor(rnd() * 900)) * 1000; this.clock = t;
            const outlet = outlets[i % outlets.length]; if (i === 0 || i === Math.floor(n / 2)) this.set_work_context({ p_outlet_id: outlet });
            const o = this.t('outlets').find((x) => x.id === outlet), tse = this.t('tses').find((x) => x.id === o?.tse_id);
            const territory = this.t('territories').find((x) => x.id === tse?.territory_id);
            const regionalProducts = products.filter((id) => !this.t('products').find((x) => x.id === id)?.state_id || this.t('products').find((x) => x.id === id)?.state_id === territory?.state_id);
            const sale = uuid();
            this.record_sale({ p_sale_id: sale, p_outlet_id: outlet, p_product_id: regionalProducts[Math.floor(rnd() * regionalProducts.length)], p_quantity: 1 + Math.floor(rnd() * 3) });
            this.clock = t + 20000; const r = this.play_spin({ p_sale_id: sale });
            this.clock = t + 45000; this.confirm_handover({ p_spin_id: r.spin_id });
          }
        }
      }
    } catch (e) { console.warn('demo history stopped:', e.message); }
    this.clock = null; this.uid = null;
    this.t('activity_flags').length = 0;   // keep the demo flag list clean
    this.save();
  }
}
