// Master data cached on the phone for fast / offline outlet selection
import { selectAll } from './api.js';
import { store } from './store.js';

const KEY = 'rio.masters';

export function cachedMasters() { return store.get(KEY); }

export async function loadMasters({ force = false } = {}) {
  const cached = store.get(KEY);
  if (cached && !force && Date.now() - cached.at < 6 * 3600 * 1000) return cached;
  try {
    const [states, territories, tses, outlets, products, prizes] = await Promise.all([
      selectAll('states', 'id,code,name', (q) => q.eq('status', 'active').order('name')),
      selectAll('territories', 'id,code,name,state_id', (q) => q.eq('status', 'active').order('name')),
      selectAll('tses', 'id,code,name,territory_id', (q) => q.eq('status', 'active').order('name')),
      selectAll('outlets', 'id,outlet_code,name,area,city,tse_id', (q) => q.eq('status', 'active').order('name')),
      selectAll('products', 'id,sku_code,name,pack,size_ml,sort_order', (q) => q.eq('is_active', true).order('sort_order')),
      selectAll('prizes', 'id,code,name,short_name,tier,wheel_label,win_title,win_subtitle,image_url,sort_order', (q) => q.eq('is_active', true).order('sort_order')),
    ]);
    const m = { at: Date.now(), states, territories, tses, outlets, products, prizes };
    store.set(KEY, m);
    return m;
  } catch (e) {
    if (cached) return { ...cached, stale: true };
    throw e;
  }
}
