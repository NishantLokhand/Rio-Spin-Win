import { supabase } from './supabase.js';

const MESSAGES = {
  NETWORK: 'No network connection. Check signal and try again.',
  NOT_AUTHENTICATED: 'Please log in again.',
  USER_DISABLED: 'Your account has been disabled. Contact your supervisor.',
  PENDING_HANDOVER: 'Hand over the previous prize first.',
  OUTLET_NOT_ACTIVE: 'This outlet is not active in the outlet master.',
  NO_ACTIVE_CAMPAIGN: 'No active campaign covers this outlet.',
  PRODUCT_NOT_ALLOWED: 'This SKU is not part of the campaign.',
  INVALID_QUANTITY: 'Invalid quantity.',
  OUT_OF_STOCK: 'Prize stock needed',
  BUDGET_EXHAUSTED: 'Campaign budget exhausted.',
  NO_PRIZE_CONFIG: 'Prizes are not configured for this campaign.',
  SALE_NOT_FOUND: 'Sale not found.',
  NO_SPINS_LEFT: 'This sale has already used its spin.',
  SALE_ALREADY_SPUN: 'A spin result is permanent and cannot be cancelled.',
  COST_ABOVE_TARGET: 'This prize configuration exceeds the campaign cost target.',
  OVERRIDE_NOT_AUTHORISED: 'You are not authorised to override the cost target.',
  POOL_SIZE_MISMATCH: 'Prize quantities must add up to the pool size.',
  NOT_AUTHORISED: 'You are not authorised to do this.',
  ADMIN_ONLY: 'Admin only.',
  STAFF_ONLY: 'Supervisor or admin only.',
  INSUFFICIENT_STOCK: 'Not enough stock.',
  NOTE_REQUIRED: 'Please add a note.',
  TSE_REQUIRED: 'Select a TSE for the outlet.',
  OUTLET_CODE_EXISTS: 'That outlet code already exists.',
  VALIDATION_REQUIRED: 'Required sale validation missing.',
};

export class ApiError extends Error {
  constructor(code, hint, detail, network = false) {
    super(hint || MESSAGES[code] || code);
    this.code = code; this.hint = hint; this.detail = detail; this.network = network;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isNetwork = (err) => !err?.code && /fetch|network|load failed|timeout/i.test(err?.message || '');

/** Call a Postgres function. Our write RPCs are idempotent, so retries are safe. */
export async function rpc(fn, args = {}, { retries = 0 } = {}) {
  for (let attempt = 0; ; attempt++) {
    let res;
    try {
      res = await supabase.rpc(fn, args);
    } catch (e) {
      res = { error: { message: String(e?.message || e) } };
    }
    const { data, error } = res;
    if (!error) return data;
    if (isNetwork(error) || (typeof navigator !== 'undefined' && !navigator.onLine)) {
      if (attempt < retries) { await sleep(Math.min(800 * 2 ** attempt, 5000)); continue; }
      throw new ApiError('NETWORK', MESSAGES.NETWORK, null, true);
    }
    const code = error.message;
    throw new ApiError(code, error.hint || MESSAGES[code] || error.details || code, error.details);
  }
}

/** Select all rows (pages past the 1000-row API limit) */
export async function selectAll(table, columns = '*', build = (q) => q, pageSize = 1000) {
  const out = [];
  for (let from = 0; ; from += pageSize) {
    let q = supabase.from(table).select(columns).range(from, from + pageSize - 1);
    q = build(q);
    const { data, error } = await q;
    if (error) throw new ApiError(error.message, error.hint || error.message);
    out.push(...data);
    if (data.length < pageSize) return out;
  }
}

export function friendly(err) {
  if (!err) return '';
  if (err instanceof ApiError) return err.message;
  return err.message || String(err);
}
