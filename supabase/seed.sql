-- =====================================================================
-- RIO SPIN & WIN — DEMO / INITIAL SEED DATA
-- Master data + the RIO SPIN & WIN 2026 campaign with the initial
-- 200-spin prize structure. Users are created by scripts/create-users.mjs
-- =====================================================================

-- States
insert into public.states (id, code, name) values
  ('10000000-0000-0000-0000-000000000001', 'UP', 'Uttar Pradesh'),
  ('10000000-0000-0000-0000-000000000002', 'MH', 'Maharashtra');

-- Territories
insert into public.territories (id, state_id, code, name) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'UP-LKO-C', 'Lucknow Central'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'UP-KNP',   'Kanpur'),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 'MH-MUM-W', 'Mumbai West'),
  ('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002', 'MH-PUN',   'Pune');

-- TSEs (Good Drop salespeople — separate from promoters)
insert into public.tses (id, territory_id, code, name, mobile) values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'TSE-UP-001', 'Rahul Sharma',   '9810000001'),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'TSE-UP-002', 'Amit Verma',     '9810000002'),
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'TSE-UP-003', 'Sanjay Gupta',   '9810000003'),
  ('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000003', 'TSE-MH-001', 'Priya Deshmukh', '9820000001'),
  ('30000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000004', 'TSE-MH-002', 'Nikhil Patil',   '9820000002');

-- Outlets
insert into public.outlets (tse_id, outlet_code, name, area, city, distributor) values
  ('30000000-0000-0000-0000-000000000001', 'LKO-0001', 'Modern Wines',        'Hazratganj',   'Lucknow', 'Awadh Beverages'),
  ('30000000-0000-0000-0000-000000000001', 'LKO-0002', 'City Liquors',        'Aminabad',     'Lucknow', 'Awadh Beverages'),
  ('30000000-0000-0000-0000-000000000001', 'LKO-0003', 'Royal Wine Shop',     'Gomti Nagar',  'Lucknow', 'Awadh Beverages'),
  ('30000000-0000-0000-0000-000000000001', 'LKO-0004', 'Metro Wines',         'Alambagh',     'Lucknow', 'Awadh Beverages'),
  ('30000000-0000-0000-0000-000000000001', 'LKO-0005', 'Nawab Wine & Beer',   'Kaiserbagh',   'Lucknow', 'Awadh Beverages'),
  ('30000000-0000-0000-0000-000000000002', 'LKO-0101', 'Royal Liquors',       'Indira Nagar', 'Lucknow', 'Lucknow Spirits Co'),
  ('30000000-0000-0000-0000-000000000002', 'LKO-0102', 'City Wine Shop',      'Aliganj',      'Lucknow', 'Lucknow Spirits Co'),
  ('30000000-0000-0000-0000-000000000002', 'LKO-0103', 'Party Point',         'Mahanagar',    'Lucknow', 'Lucknow Spirits Co'),
  ('30000000-0000-0000-0000-000000000003', 'KNP-0001', 'Ganga Wines',         'Swaroop Nagar','Kanpur',  'Kanpur Distributors'),
  ('30000000-0000-0000-0000-000000000003', 'KNP-0002', 'Mall Road Liquors',   'Mall Road',    'Kanpur',  'Kanpur Distributors'),
  ('30000000-0000-0000-0000-000000000004', 'MUM-0001', 'Bandra Wine Stores',  'Bandra West',  'Mumbai',  'Western Beverages'),
  ('30000000-0000-0000-0000-000000000004', 'MUM-0002', 'Andheri Wine Mart',   'Andheri West', 'Mumbai',  'Western Beverages'),
  ('30000000-0000-0000-0000-000000000004', 'MUM-0003', 'Juhu Cellar',         'Juhu',         'Mumbai',  'Western Beverages'),
  ('30000000-0000-0000-0000-000000000005', 'PUN-0001', 'FC Road Wines',       'Shivajinagar', 'Pune',    'Deccan Drinks'),
  ('30000000-0000-0000-0000-000000000005', 'PUN-0002', 'Koregaon Park Cellar','Koregaon Park','Pune',    'Deccan Drinks');

-- Products / SKUs (edit in Admin → Products)
insert into public.products (id, sku_code, name, pack, size_ml, mrp, sort_order) values
  ('40000000-0000-0000-0000-000000000001', 'RIO-GT-500C', 'Rio Gold Tropical 500 ml Can', 'Can',    500, null, 1),
  ('40000000-0000-0000-0000-000000000002', 'RIO-SR-500C', 'Rio Strong Red 500 ml Can',    'Can',    500, null, 2),
  ('40000000-0000-0000-0000-000000000003', 'RIO-SG-500C', 'Rio Strong Gold 500 ml Can',   'Can',    500, null, 3),
  ('40000000-0000-0000-0000-000000000004', 'RIO-GT-750B', 'Rio Gold Tropical 750 ml',     'Bottle', 750, null, 4);

-- Prizes (wheel_label = comma list of wheel segments the wheel may land on for this prize)
insert into public.prizes (id, code, name, short_name, tier, default_cost, wheel_label, win_title, win_subtitle, low_stock_threshold, sort_order) values
  ('50000000-0000-0000-0000-000000000001', 'SNACK5',   '₹5 Snack',                   '₹5 Snack',  'standard', 5,   '₹5 SNACK',                       'YOU WON! 🎉',             'SNACK TIME!',                  15, 1),
  ('50000000-0000-0000-0000-000000000002', 'SNACK10',  '₹10 Snack',                  '₹10 Snack', 'standard', 10,  '₹10 SNACK',                      'YOU WON! 🎉',             'SNACK TIME!',                  5,  2),
  ('50000000-0000-0000-0000-000000000003', 'RIODARE',  'Rio Dare Card Game',         'Rio Dare',  'mid',      40,  'RIO DARE CARD GAME',              '🔥 YOU WON RIO DARE! 🔥',  'LET THE GAMES BEGIN',          2,  3),
  ('50000000-0000-0000-0000-000000000004', 'SHADES',   'Rio Sunglasses',             'Rio Shades','high',     100, 'RIO SUNGLASSES',                  '😎 YOU WON RIO SHADES!',   'LOOKING COOL!',                1,  4),
  ('50000000-0000-0000-0000-000000000005', 'SPEAKER',  'Rio Mini Bluetooth Speaker', 'Speaker',   'jackpot',  200, 'RIO MINI BLUETOOTH SPEAKER',      '🎵 RIO MINI BLUETOOTH SPEAKER!', 'YOU WON RIO MINI BLUETOOTH SPEAKER!', 0,  5);

-- Campaign
insert into public.campaigns (id, code, name, status, start_date, end_date, target_cost_per_spin,
                              total_budget, daily_budget, pool_scope, draw_strategy, oos_mode, config_change_mode)
values ('60000000-0000-0000-0000-000000000001', 'RSW-2026', 'RIO SPIN & WIN 2026', 'active',
        '2026-09-01', '2026-12-31', 10, 500000, 25000, 'campaign', 'controlled_pool', 'defer', 'next_pool');

insert into public.campaign_states (campaign_id, state_id, budget) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 300000),
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 200000);

insert into public.campaign_products (campaign_id, product_id, sort_order)
select '60000000-0000-0000-0000-000000000001', id, sort_order from public.products;

-- Initial prize structure: 200 spins = ₹2,000 = ₹10/spin
insert into public.prize_configs (id, campaign_id, state_id, version, pool_size, total_cost, avg_cost, target_cost, is_active, notes)
values ('70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', null, 1, 200, 2000, 10, 10, true,
        'Initial RIO SPIN & WIN 2026 structure');

insert into public.prize_config_items (config_id, prize_id, quantity, unit_cost) values
  ('70000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 152, 5),
  ('70000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 34, 10),
  ('70000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 10, 40),
  ('70000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000004', 3, 100),
  ('70000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000005', 1, 200);
