// Demo seed — mirrors supabase/seed.sql + demo users + opening stock kits
const now = () => new Date().toISOString();
const ST_UP = '10000000-0000-0000-0000-000000000001', ST_MH = '10000000-0000-0000-0000-000000000002';
const T = (n) => `20000000-0000-0000-0000-00000000000${n}`;
const TSE = (n) => `30000000-0000-0000-0000-00000000000${n}`;
const PR = (n) => `50000000-0000-0000-0000-00000000000${n}`;
const PD = (n) => `40000000-0000-0000-0000-00000000000${n}`;
export const CAMPAIGN = '60000000-0000-0000-0000-000000000001';
export const U = { admin: 'a0000000-0000-0000-0000-000000000001', sup: 'a0000000-0000-0000-0000-000000000002',
  p1: 'a0000000-0000-0000-0000-000000000003', p2: 'a0000000-0000-0000-0000-000000000004', supm: 'a0000000-0000-0000-0000-000000000005',
  p3: 'a0000000-0000-0000-0000-000000000006' };

export function seedDb() {
  const ts = now();
  const rec = (o) => ({ status: 'active', external_ref: null, created_at: ts, updated_at: ts, ...o });
  const outlets = [
    [1, 'LKO-0001', 'Modern Wines', 'Hazratganj', 'Lucknow', 'Awadh Beverages'], [1, 'LKO-0002', 'City Liquors', 'Aminabad', 'Lucknow', 'Awadh Beverages'],
    [1, 'LKO-0003', 'Royal Wine Shop', 'Gomti Nagar', 'Lucknow', 'Awadh Beverages'], [1, 'LKO-0004', 'Metro Wines', 'Alambagh', 'Lucknow', 'Awadh Beverages'],
    [1, 'LKO-0005', 'Nawab Wine & Beer', 'Kaiserbagh', 'Lucknow', 'Awadh Beverages'], [2, 'LKO-0101', 'Royal Liquors', 'Indira Nagar', 'Lucknow', 'Lucknow Spirits Co'],
    [2, 'LKO-0102', 'City Wine Shop', 'Aliganj', 'Lucknow', 'Lucknow Spirits Co'], [2, 'LKO-0103', 'Party Point', 'Mahanagar', 'Lucknow', 'Lucknow Spirits Co'],
    [3, 'KNP-0001', 'Ganga Wines', 'Swaroop Nagar', 'Kanpur', 'Kanpur Distributors'], [3, 'KNP-0002', 'Mall Road Liquors', 'Mall Road', 'Kanpur', 'Kanpur Distributors'],
    [4, 'MUM-0001', 'Bandra Wine Stores', 'Bandra West', 'Mumbai', 'Western Beverages'], [4, 'MUM-0002', 'Andheri Wine Mart', 'Andheri West', 'Mumbai', 'Western Beverages'],
    [4, 'MUM-0003', 'Juhu Cellar', 'Juhu', 'Mumbai', 'Western Beverages'], [5, 'PUN-0001', 'FC Road Wines', 'Shivajinagar', 'Pune', 'Deccan Drinks'],
    [5, 'PUN-0002', 'Koregaon Park Cellar', 'Koregaon Park', 'Pune', 'Deccan Drinks'],
  ].map(([t, code, name, area, city, dist], i) => rec({ id: `80000000-0000-0000-0000-${String(i + 1).padStart(12, '0')}`, tse_id: TSE(t),
    outlet_code: code, name, area, city, distributor: dist, source: 'master', latitude: null, longitude: null }));

  const prizes = [
    [1, 'SNACK5', '₹5 Snack', '₹5 Snack', 'standard', 5, 'SNACK ATTACK,TREAT YOURSELF', 'YOU WON! 🎉', 'SNACK TIME!', 15],
    [2, 'SNACK10', '₹10 Snack', '₹10 Snack', 'standard', 10, 'CRUNCH TIME,RIO SURPRISE', 'YOU WON! 🎉', 'SNACK TIME!', 5],
    [3, 'RIODARE', 'Rio Dare Card Game', 'Rio Dare', 'mid', 40, 'RIO DARE,WIN BIG', '🔥 YOU WON RIO DARE! 🔥', 'LET THE GAMES BEGIN', 2],
    [4, 'SHADES', 'Rio Sunglasses', 'Rio Shades', 'high', 100, 'RIO SHADES', '😎 YOU WON RIO SHADES!', 'LOOKING COOL!', 1],
    [5, 'SPEAKER', 'Rio Mini Bluetooth Speaker', 'Speaker', 'jackpot', 200, 'RIO PARTY JACKPOT', '🎵 RIO PARTY JACKPOT! 🎵', 'YOU WON A BLUETOOTH SPEAKER!', 0],
  ].map(([n, code, name, short, tier, cost, wl, wt, ws, thr]) => ({ id: PR(n), code, name, short_name: short, tier, default_cost: cost, image_url: null,
    wheel_label: wl, win_title: wt, win_subtitle: ws, low_stock_threshold: thr, is_active: true, sort_order: n, created_at: ts, updated_at: ts }));

  const users = [
    [U.admin, 'admin', 'admin', 'Campaign Admin', null, 'admin123', true, true],
    [U.sup, 'supervisor', 'sup.lucknow', 'Vikas Tiwari', '9000000001', '222222', true, false],
    [U.supm, 'supervisor', 'sup.mumbai', 'Rohan Kulkarni', '9000000002', '222222', false, false],
    [U.p1, 'promoter', '9876500001', 'Ravi Kumar', '9876500001', '111111', false, false],
    [U.p2, 'promoter', '9876500002', 'Sneha Yadav', '9876500002', '111111', false, false],
    [U.p3, 'promoter', '9876500003', 'Arjun Patil', '9876500003', '111111', false, false],
  ];

  const kit = [[1, 152], [2, 34], [3, 10], [4, 3], [5, 1]];
  const inv = []; const moves = [];
  for (const p of [U.p1, U.p2, U.p3]) for (const [n, q] of kit) {
    inv.push({ promoter_id: p, prize_id: PR(n), on_hand: q, reserved: 0, updated_at: ts });
    moves.push({ id: crypto.randomUUID(), promoter_id: p, prize_id: PR(n), movement_type: 'issue', qty: q, on_hand_after: q, spin_id: null, performed_by: U.admin, reference: 'Opening kit', note: 'Demo opening stock', created_at: ts });
  }

  return {
    _auth: users.map(([id, , login, , , pin]) => ({ id, email: login, password: pin })),
    states: [rec({ id: ST_UP, code: 'UP', name: 'Uttar Pradesh' }), rec({ id: ST_MH, code: 'MH', name: 'Maharashtra' })],
    territories: [rec({ id: T(1), state_id: ST_UP, code: 'UP-LKO-C', name: 'Lucknow Central' }), rec({ id: T(2), state_id: ST_UP, code: 'UP-KNP', name: 'Kanpur' }),
      rec({ id: T(3), state_id: ST_MH, code: 'MH-MUM-W', name: 'Mumbai West' }), rec({ id: T(4), state_id: ST_MH, code: 'MH-PUN', name: 'Pune' })],
    tses: [rec({ id: TSE(1), territory_id: T(1), code: 'TSE-UP-001', name: 'Rahul Sharma', mobile: '9810000001' }),
      rec({ id: TSE(2), territory_id: T(1), code: 'TSE-UP-002', name: 'Amit Verma', mobile: '9810000002' }),
      rec({ id: TSE(3), territory_id: T(2), code: 'TSE-UP-003', name: 'Sanjay Gupta', mobile: '9810000003' }),
      rec({ id: TSE(4), territory_id: T(3), code: 'TSE-MH-001', name: 'Priya Deshmukh', mobile: '9820000001' }),
      rec({ id: TSE(5), territory_id: T(4), code: 'TSE-MH-002', name: 'Nikhil Patil', mobile: '9820000002' })],
    outlets,
    app_users: users.map(([id, role, login, name, mobile, , approve, override]) => ({ id, role, login_id: login, full_name: name, mobile, email: null,
      is_active: true, can_approve_outlets: approve, can_override_cost_target: override, created_at: ts, updated_at: ts })),
    promoters: [
      { user_id: U.p1, promoter_code: 'PRM-001', promoter_type: 'permanent', agency_name: null, supervisor_id: U.sup, home_state_id: ST_UP, joined_on: null, notes: null, created_at: ts, updated_at: ts },
      { user_id: U.p2, promoter_code: 'PRM-002', promoter_type: 'agency', agency_name: 'BrandBuzz Activations', supervisor_id: U.sup, home_state_id: ST_UP, joined_on: null, notes: null, created_at: ts, updated_at: ts },
      { user_id: U.p3, promoter_code: 'PRM-003', promoter_type: 'spot_selling', agency_name: null, supervisor_id: U.supm, home_state_id: ST_MH, joined_on: null, notes: null, created_at: ts, updated_at: ts },
    ],
    products: [
      [1, 'RIO-GT-500C', 'Rio Gold Tropical 500 ml Can', 'Can', 500], [2, 'RIO-SR-500C', 'Rio Strong Red 500 ml Can', 'Can', 500],
      [3, 'RIO-SG-500C', 'Rio Strong Gold 500 ml Can', 'Can', 500], [4, 'RIO-GT-750B', 'Rio Gold Tropical 750 ml', 'Bottle', 750],
    ].map(([n, sku, name, pack, ml]) => ({ id: PD(n), sku_code: sku, name, pack, size_ml: ml, mrp: null, is_active: true, sort_order: n, external_ref: null, created_at: ts, updated_at: ts })),
    prizes,
    campaigns: [{ id: CAMPAIGN, code: 'RSW-2026', name: 'RIO SPIN & WIN 2026', status: 'active', start_date: '2026-01-01', end_date: '2027-12-31',
      target_cost_per_spin: 10, total_budget: 500000, daily_budget: 25000, enforce_budget: false, pool_scope: 'promoter', draw_strategy: 'controlled_pool',
      oos_mode: 'defer', config_change_mode: 'next_pool', track_inventory: true, spins_per_sale: 1, max_quantity_per_sale: 24, validation_rules: {},
      capture_consumer: false, sound_default: true, work_start: '09:00', work_end: '22:30',
      flag_rules: { min_seconds_between_spins: 20, max_spins_per_day: 250, high_value_cost: 100, max_high_value_per_day: 3, max_cancelled_per_day: 5,
        max_outlet_requests_per_day: 3, slow_handover_minutes: 20, stale_pending_minutes: 30 }, created_at: ts, updated_at: ts }],
    campaign_states: [{ campaign_id: CAMPAIGN, state_id: ST_UP, budget: 300000 }, { campaign_id: CAMPAIGN, state_id: ST_MH, budget: 200000 }],
    campaign_territory_budgets: [],
    campaign_products: [1, 2, 3, 4].map((n) => ({ campaign_id: CAMPAIGN, product_id: PD(n), sort_order: n })),
    campaign_promoters: [],
    prize_configs: [{ id: '70000000-0000-0000-0000-000000000001', campaign_id: CAMPAIGN, state_id: null, version: 1, pool_size: 200, total_cost: 2000,
      avg_cost: 10, target_cost: 10, exceeds_target: false, override_by: null, is_active: true, notes: 'Initial RIO SPIN & WIN 2026 structure', created_by: U.admin, created_at: ts }],
    prize_config_items: kit.map(([n, q]) => ({ config_id: '70000000-0000-0000-0000-000000000001', prize_id: PR(n), quantity: q, unit_cost: [0, 5, 10, 40, 100, 200][n] })),
    prize_pools: [], prize_pool_slots: [], promoter_sessions: [], sales: [], spins: [],
    promoter_inventory: inv, inventory_movements: moves, outlet_requests: [], activity_flags: [], audit_logs: [],
    sale_validations: [], consumers: [], _storage: {}, _seq: 0,
  };
}
