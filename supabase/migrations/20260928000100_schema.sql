-- =====================================================================
-- RIO SPIN & WIN — 001 SCHEMA
-- Good Drop Wine Cellars · consumer spot-selling activation platform
-- Target: Supabase Postgres (15+)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------
create type public.user_role          as enum ('promoter','supervisor','admin');
create type public.promoter_type      as enum ('permanent','temporary','spot_selling','agency');
create type public.pool_scope         as enum ('promoter','outlet','territory','state','campaign');
create type public.draw_strategy      as enum ('controlled_pool','weighted_random');
create type public.oos_mode           as enum ('defer','block','substitute');
create type public.config_change_mode as enum ('next_pool','regenerate_now');
create type public.sale_status        as enum ('open','spun','completed','cancelled');
create type public.redemption_status  as enum ('pending','handed_over','not_redeemed');
create type public.movement_type      as enum ('issue','award','return','damaged','missing','adjustment');
create type public.request_status     as enum ('pending','approved','rejected');
create type public.flag_status        as enum ('open','reviewed','dismissed');
create type public.record_status      as enum ('active','inactive');

-- ---------------------------------------------------------------------
-- GEOGRAPHY / SALES HIERARCHY :  STATE → TERRITORY → TSE → OUTLET
-- ---------------------------------------------------------------------
create table public.states (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  name         text not null unique,
  status       record_status not null default 'active',
  external_ref text,                       -- for SFA / ERP mapping
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.territories (
  id           uuid primary key default gen_random_uuid(),
  state_id     uuid not null references public.states(id),
  code         text not null unique,
  name         text not null,
  status       record_status not null default 'active',
  external_ref text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (state_id, name)
);

-- TSE = Good Drop salesperson responsible for outlets. NOT the promoter.
create table public.tses (
  id           uuid primary key default gen_random_uuid(),
  territory_id uuid not null references public.territories(id),
  code         text not null unique,
  name         text not null,
  mobile       text,
  status       record_status not null default 'active',
  external_ref text,                       -- FieldAssist employee code etc.
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.outlets (
  id           uuid primary key default gen_random_uuid(),
  tse_id       uuid not null references public.tses(id),
  outlet_code  text not null unique,
  name         text not null,
  area         text,
  city         text,
  distributor  text,
  status       record_status not null default 'active',
  source       text not null default 'master' check (source in ('master','upload','request')),
  latitude     numeric(9,6),
  longitude    numeric(9,6),
  external_ref text,                       -- FieldAssist / distributor outlet id
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index outlets_tse_idx on public.outlets(tse_id) where status = 'active';

-- ---------------------------------------------------------------------
-- USERS
-- ---------------------------------------------------------------------
create table public.app_users (
  id                        uuid primary key references auth.users(id) on delete cascade,
  role                      user_role not null,
  login_id                  text not null unique,   -- mobile number or username
  full_name                 text not null,
  mobile                    text,
  email                     text,
  is_active                 boolean not null default true,
  can_approve_outlets       boolean not null default false,  -- supervisors
  can_override_cost_target  boolean not null default false,  -- admins
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

-- Promoter is a separate entity from TSE. Kept as its own table.
create table public.promoters (
  user_id        uuid primary key references public.app_users(id) on delete cascade,
  promoter_code  text not null unique,
  promoter_type  promoter_type not null default 'permanent',
  agency_name    text,
  supervisor_id  uuid references public.app_users(id),
  home_state_id  uuid references public.states(id),
  joined_on      date,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index promoters_supervisor_idx on public.promoters(supervisor_id);

-- ---------------------------------------------------------------------
-- PRODUCTS / SKUs
-- ---------------------------------------------------------------------
create table public.products (
  id           uuid primary key default gen_random_uuid(),
  sku_code     text not null unique,
  name         text not null,
  pack         text,
  size_ml      int,
  mrp          numeric(10,2),
  is_active    boolean not null default true,
  sort_order   int not null default 100,
  external_ref text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- PRIZES (catalogue — costs per campaign live in prize_config_items)
-- ---------------------------------------------------------------------
create table public.prizes (
  id                   uuid primary key default gen_random_uuid(),
  code                 text not null unique,
  name                 text not null,               -- "Rio Mini Bluetooth Speaker"
  short_name           text not null,               -- "Speaker"
  tier                 text not null default 'standard'
                         check (tier in ('standard','mid','high','jackpot')),
  default_cost         numeric(10,2) not null default 0,
  image_url            text,
  wheel_label          text,                         -- label the wheel lands on
  win_title            text,
  win_subtitle         text,
  low_stock_threshold  int not null default 2,
  is_active            boolean not null default true,
  sort_order           int not null default 100,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- CAMPAIGNS — the spin rule is CONFIGURATION, not code
-- ---------------------------------------------------------------------
create table public.campaigns (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique,
  name                  text not null,
  status                text not null default 'active'
                          check (status in ('draft','active','paused','closed')),
  start_date            date,
  end_date              date,
  target_cost_per_spin  numeric(10,2) not null default 10,
  total_budget          numeric(14,2),
  daily_budget          numeric(14,2),
  enforce_budget        boolean not null default false,
  -- spin rule
  pool_scope            pool_scope         not null default 'promoter',
  draw_strategy         draw_strategy      not null default 'controlled_pool',
  oos_mode              oos_mode           not null default 'defer',
  config_change_mode    config_change_mode not null default 'next_pool',
  track_inventory       boolean not null default true,
  spins_per_sale        int not null default 1 check (spins_per_sale between 1 and 10),
  max_quantity_per_sale int not null default 24,
  -- optional validation / consumer capture (off by default)
  validation_rules      jsonb not null default '{}'::jsonb,  -- e.g. {"invoice_no":"required","receipt_photo":"optional"}
  capture_consumer      boolean not null default false,
  sound_default         boolean not null default true,
  -- fraud rules
  work_start            time not null default '09:00',
  work_end              time not null default '22:30',
  flag_rules            jsonb not null default '{
      "min_seconds_between_spins": 20,
      "max_spins_per_day": 250,
      "high_value_cost": 100,
      "max_high_value_per_day": 3,
      "max_cancelled_per_day": 5,
      "max_outlet_requests_per_day": 3,
      "slow_handover_minutes": 20,
      "stale_pending_minutes": 30
  }'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- Geographic coverage (+ state budget)
create table public.campaign_states (
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  state_id    uuid not null references public.states(id),
  budget      numeric(14,2),
  primary key (campaign_id, state_id)
);

create table public.campaign_territory_budgets (
  campaign_id  uuid not null references public.campaigns(id) on delete cascade,
  territory_id uuid not null references public.territories(id),
  budget       numeric(14,2) not null,
  primary key (campaign_id, territory_id)
);

-- Empty = all promoters eligible
create table public.campaign_promoters (
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  promoter_id uuid not null references public.promoters(user_id),
  primary key (campaign_id, promoter_id)
);

-- Empty = all active products eligible
create table public.campaign_products (
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  product_id  uuid not null references public.products(id),
  sort_order  int not null default 100,
  primary key (campaign_id, product_id)
);

-- ---------------------------------------------------------------------
-- PRIZE CONFIGURATION (versioned) — per campaign, optionally per state
-- ---------------------------------------------------------------------
create table public.prize_configs (
  id              uuid primary key default gen_random_uuid(),
  campaign_id     uuid not null references public.campaigns(id),
  state_id        uuid references public.states(id),     -- null = campaign default
  version         int  not null,
  pool_size       int  not null check (pool_size > 0),
  total_cost      numeric(14,2) not null,
  avg_cost        numeric(10,4) not null,
  target_cost     numeric(10,2) not null,
  exceeds_target  boolean not null default false,
  override_by     uuid references public.app_users(id),
  is_active       boolean not null default false,
  notes           text,
  created_by      uuid references public.app_users(id),
  created_at      timestamptz not null default now(),
  unique (campaign_id, version)
);
create unique index prize_configs_one_active
  on public.prize_configs (campaign_id, coalesce(state_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where is_active;

create table public.prize_config_items (
  config_id  uuid not null references public.prize_configs(id) on delete cascade,
  prize_id   uuid not null references public.prizes(id),
  quantity   int  not null check (quantity >= 0),
  unit_cost  numeric(10,2) not null check (unit_cost >= 0),
  primary key (config_id, prize_id)
);

-- ---------------------------------------------------------------------
-- PRIZE POOLS — the hidden, pre-shuffled outcome sequence
-- ---------------------------------------------------------------------
create table public.prize_pools (
  id           uuid primary key default gen_random_uuid(),
  campaign_id  uuid not null references public.campaigns(id),
  config_id    uuid not null references public.prize_configs(id),
  scope        pool_scope not null,
  scope_key    text not null,          -- promoter id / outlet id / ... depending on scope
  pool_no      int  not null,
  size         int  not null,
  used         int  not null default 0,
  created_at   timestamptz not null default now(),
  exhausted_at timestamptz,
  voided_at    timestamptz,
  void_reason  text,
  unique (campaign_id, scope, scope_key, pool_no)
);
create unique index prize_pools_one_open
  on public.prize_pools (campaign_id, scope, scope_key)
  where exhausted_at is null and voided_at is null;

-- NOBODY (not even admin) can read this table through the API.
create table public.prize_pool_slots (
  pool_id     uuid not null references public.prize_pools(id),
  position    int  not null,
  prize_id    uuid not null references public.prizes(id),
  unit_cost   numeric(10,2) not null,
  used_at     timestamptz,
  spin_id     uuid,
  deferred_at timestamptz,             -- first time skipped because of no stock
  primary key (pool_id, position)
);
create index prize_pool_slots_open on public.prize_pool_slots(pool_id, position) where used_at is null;

-- ---------------------------------------------------------------------
-- PROMOTER WORK SESSION (server copy of session memory)
-- ---------------------------------------------------------------------
create table public.promoter_sessions (
  id            uuid primary key default gen_random_uuid(),
  promoter_id   uuid not null references public.promoters(user_id),
  work_date     date not null,
  campaign_id   uuid references public.campaigns(id),
  state_id      uuid references public.states(id),
  territory_id  uuid references public.territories(id),
  tse_id        uuid references public.tses(id),
  outlet_id     uuid references public.outlets(id),
  device_ref    text,
  started_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (promoter_id, work_date)
);

-- ---------------------------------------------------------------------
-- OPTIONAL CONSUMER DATA (disabled for v1 — structure only)
-- ---------------------------------------------------------------------
create table public.consumers (
  id          uuid primary key default gen_random_uuid(),
  name        text,
  mobile      text,
  consent     boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- SALES (transaction header) — snapshot of hierarchy at time of sale
-- ---------------------------------------------------------------------
create table public.sales (
  id                uuid primary key,             -- generated on the phone → idempotent
  campaign_id       uuid not null references public.campaigns(id),
  biz_date          date not null,
  created_at        timestamptz not null default now(),
  client_created_at timestamptz,
  -- promoter snapshot
  promoter_id       uuid not null references public.promoters(user_id),
  promoter_code     text not null,
  promoter_name     text not null,
  promoter_type     promoter_type not null,
  -- hierarchy snapshot
  state_id          uuid not null,
  state_name        text not null,
  territory_id      uuid not null,
  territory_name    text not null,
  tse_id            uuid not null,
  tse_code          text not null,
  tse_name          text not null,
  outlet_id         uuid not null,
  outlet_code       text not null,
  outlet_name       text not null,
  outlet_area       text,
  outlet_city       text,
  distributor       text,
  -- product snapshot
  product_id        uuid not null,
  sku_code          text not null,
  product_name      text not null,
  quantity          int  not null check (quantity > 0),
  -- control
  spins_allowed     int  not null default 1,
  spins_used        int  not null default 0,
  status            sale_status not null default 'open',
  cancelled_reason  text,
  validation        jsonb not null default '{}'::jsonb,
  consumer_id       uuid references public.consumers(id),
  device_ref        text,
  session_ref       text
);
create index sales_promoter_date on public.sales(promoter_id, biz_date);
create index sales_campaign_date on public.sales(campaign_id, biz_date);
create index sales_outlet on public.sales(outlet_id);
create index sales_tse on public.sales(tse_id);

-- Future: invoice / receipt / QR / barcode / photo / retailer confirmation
create table public.sale_validations (
  id          uuid primary key default gen_random_uuid(),
  sale_id     uuid not null references public.sales(id),
  kind        text not null check (kind in ('invoice_no','receipt_no','qr_code','barcode','receipt_photo','retailer_confirmation')),
  value       text,
  file_url    text,
  status      text not null default 'submitted' check (status in ('submitted','verified','rejected')),
  verified_by uuid references public.app_users(id),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- SPINS — one row per spin, result is permanent
-- ---------------------------------------------------------------------
create sequence public.spin_code_seq;

create table public.spins (
  id                 uuid primary key default gen_random_uuid(),
  spin_code          text not null unique,
  sale_id            uuid not null references public.sales(id),
  spin_no            int  not null default 1,
  campaign_id        uuid not null references public.campaigns(id),
  promoter_id        uuid not null references public.promoters(user_id),
  biz_date           date not null,
  created_at         timestamptz not null default now(),
  -- how the result was produced
  strategy           draw_strategy not null,
  pool_id            uuid references public.prize_pools(id),
  slot_position      int,
  config_id          uuid not null references public.prize_configs(id),
  config_version     int  not null,
  -- prize snapshot
  prize_id           uuid not null references public.prizes(id),
  prize_code         text not null,
  prize_name         text not null,
  prize_tier         text not null,
  prize_cost         numeric(10,2) not null,
  original_prize_id  uuid references public.prizes(id),   -- if substituted
  substituted        boolean not null default false,
  -- redemption
  redemption_status  redemption_status not null default 'pending',
  handed_over_at     timestamptz,
  inventory_status   text not null default 'reserved'
                       check (inventory_status in ('reserved','deducted','released','not_tracked')),
  resolved_by        uuid references public.app_users(id),
  resolution_note    text,
  device_ref         text,
  unique (sale_id, spin_no)
);
create index spins_promoter_date on public.spins(promoter_id, biz_date);
create index spins_campaign_date on public.spins(campaign_id, biz_date);
create index spins_pending on public.spins(promoter_id) where redemption_status = 'pending';

-- ---------------------------------------------------------------------
-- PRIZE INVENTORY (balance) + MOVEMENTS (ledger)
-- ---------------------------------------------------------------------
create table public.promoter_inventory (
  promoter_id  uuid not null references public.promoters(user_id),
  prize_id     uuid not null references public.prizes(id),
  on_hand      int  not null default 0 check (on_hand >= 0),
  reserved     int  not null default 0 check (reserved >= 0),
  updated_at   timestamptz not null default now(),
  primary key (promoter_id, prize_id),
  check (reserved <= on_hand)
);

create table public.inventory_movements (
  id             uuid primary key default gen_random_uuid(),
  promoter_id    uuid not null references public.promoters(user_id),
  prize_id       uuid not null references public.prizes(id),
  movement_type  movement_type not null,
  qty            int  not null,          -- signed change to on_hand
  on_hand_after  int  not null,
  spin_id        uuid references public.spins(id),
  performed_by   uuid references public.app_users(id),
  reference      text,
  note           text,
  created_at     timestamptz not null default now()
);
create index inventory_movements_promoter on public.inventory_movements(promoter_id, created_at desc);

-- ---------------------------------------------------------------------
-- OUTLET ADDITION REQUESTS
-- ---------------------------------------------------------------------
create table public.outlet_requests (
  id                 uuid primary key default gen_random_uuid(),
  promoter_id        uuid not null references public.promoters(user_id),
  campaign_id        uuid references public.campaigns(id),
  outlet_name        text not null,
  area               text,
  city               text,
  ref_code           text,
  suggested_tse_id   uuid references public.tses(id),
  note               text,
  status             request_status not null default 'pending',
  reviewed_by        uuid references public.app_users(id),
  reviewed_at        timestamptz,
  review_note        text,
  outlet_id          uuid references public.outlets(id),
  created_at         timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- AUDIT LOG — append-only, SHA-256 hash chained
-- ---------------------------------------------------------------------
create table public.audit_logs (
  id          bigserial primary key,
  at          timestamptz not null,
  actor_id    uuid,
  actor_role  text,
  action      text not null,
  entity      text,
  entity_id   text,
  details     jsonb not null default '{}'::jsonb,
  prev_hash   text,
  hash        text not null
);
create index audit_logs_entity on public.audit_logs(entity, entity_id);
create index audit_logs_at on public.audit_logs(at desc);

-- ---------------------------------------------------------------------
-- FRAUD / ACTIVITY FLAGS
-- ---------------------------------------------------------------------
create table public.activity_flags (
  id           uuid primary key default gen_random_uuid(),
  promoter_id  uuid references public.promoters(user_id),
  campaign_id  uuid references public.campaigns(id),
  flag_type    text not null,
  severity     text not null default 'medium' check (severity in ('low','medium','high')),
  reason       text not null,
  details      jsonb not null default '{}'::jsonb,
  flag_date    date not null,
  flag_key     text unique,              -- de-dup key for system flags (null for manual)
  occurrences  int  not null default 1,
  source       text not null default 'system' check (source in ('system','manual')),
  raised_by    uuid references public.app_users(id),
  status       flag_status not null default 'open',
  reviewed_by  uuid references public.app_users(id),
  reviewed_at  timestamptz,
  review_note  text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index activity_flags_open on public.activity_flags(status, flag_date desc);
