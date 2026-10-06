// Master data cached on the phone for fast / offline outlet selection
import { selectAll } from './api.js';
import { store } from './store.js';

// Bump cache key when product/state rules change so installed promoter devices
// refresh the regional SKU catalogue immediately after deployment.
const KEY = 'rio.masters.v2';

export function cachedMasters() { return store.get(KEY); }

export async function loadMasters({ force = false, includeOutletData = true } = {}) {
  const cached = store.get(KEY);
  if (includeOutletData && cached && !force && Date.now() - cached.at < 6 * 3600 * 1000) return cached;
  try {
    const [states, territories, tses, outlets, products, prizes] = await Promise.all([
      selectAll('states', 'id,code,name', (q) => q.eq('status', 'active').order('name')),
      selectAll('territories', 'id,code,name,state_id', (q) => q.eq('status', 'active').order('name')),
      includeOutletData ? selectAll('tses', 'id,code,name,territory_id', (q) => q.eq('status', 'active').order('name')) : Promise.resolve([]),
      includeOutletData ? selectAll('outlets', 'id,outlet_code,name,area,city,beat,distributor,tse_id,state_id,territory_id', (q) => q.eq('status', 'active').order('name')) : Promise.resolve([]),
      selectAll('products', 'id,sku_code,name,pack,size_ml,state_id,sort_order', (q) => q.eq('is_active', true).order('sort_order')),
      selectAll('prizes', 'id,code,name,short_name,tier,wheel_label,win_title,win_subtitle,image_url,sort_order', (q) => q.eq('is_active', true).order('sort_order')),
    ]);
    const m = { at: Date.now(), states, territories, tses, outlets, products, prizes };
    if (includeOutletData) store.set(KEY, m);
    return m;
  } catch (e) {
    if (includeOutletData && cached) return { ...cached, stale: true };
    throw e;
  }
}
