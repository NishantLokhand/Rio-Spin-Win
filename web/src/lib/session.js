// Promoter working-session memory: State → Territory → TSE (+ current outlet)
// Remembered for the working day; cleared on logout, day change, or manual change.
import { store, istToday } from './store.js';

const ctxKey = (uid) => `rio.ctx.${uid}`;
const recentKey = (uid) => `rio.recent.${uid}`;
const flightKey = (uid) => `rio.inflight.${uid}`;

export function getCtx(uid) {
  const c = store.get(ctxKey(uid));
  if (!c || c.date !== istToday()) return null;
  return c;
}
export function saveCtx(uid, ctx) { store.set(ctxKey(uid), { ...ctx, date: istToday() }); }
export function clearCtx(uid) { store.del(ctxKey(uid)); }

export function getRecent(uid) { return store.get(recentKey(uid), []); }
export function pushRecent(uid, outletId) {
  const list = [outletId, ...getRecent(uid).filter((x) => x !== outletId)].slice(0, 8);
  store.set(recentKey(uid), list);
}

// In-flight sale (survives refresh so the same sale / same prize is resumed, never re-drawn)
export function getInflight(uid) { return store.get(flightKey(uid)); }
export function setInflight(uid, f) { store.set(flightKey(uid), f); }
export function clearInflight(uid) { store.del(flightKey(uid)); }

export function clearAllForUser(uid) { clearCtx(uid); clearInflight(uid); }
