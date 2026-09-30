-- =====================================================================
-- RIO SPIN & WIN — COMPLETE DATABASE SETUP (paste this whole file into
-- Supabase → SQL Editor → New query → Run). Run ONCE on a new project.
-- Contains: migrations 001–005 + demo seed data. (Storage is separate.)
-- =====================================================================

-- >>> supabase/migrations/20260928000100_schema.sql
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

-- >>> supabase/migrations/20260928000200_core_functions.sql
-- =====================================================================
-- RIO SPIN & WIN — 002 CORE FUNCTIONS
-- helpers · audit chain · immutability triggers · stock ledger · flags
-- =====================================================================

-- ---------------------------------------------------------------------
-- Time helpers (business day = India Standard Time)
-- ---------------------------------------------------------------------
create or replace function public.ist_now() returns timestamp
language sql stable as $$ select now() at time zone 'Asia/Kolkata' $$;

create or replace function public.ist_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- ---------------------------------------------------------------------
-- Identity helpers
-- ---------------------------------------------------------------------
create or replace function public.my_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.app_users where id = auth.uid() and is_active
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin','supervisor'), false)
$$;

-- can the current user see data belonging to promoter p?
create or replace function public.can_see_promoter(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin()
      or (p = auth.uid() and public.my_role() is not null)
      or exists (select 1 from public.promoters pr
                  where pr.user_id = p and pr.supervisor_id = auth.uid()
                    and public.my_role() = 'supervisor')
$$;

create or replace function public._require_promoter() returns public.app_users
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users;
begin
  select * into u from public.app_users where id = auth.uid();
  if u.id is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if not u.is_active then raise exception 'USER_DISABLED' using hint = 'Your account has been disabled. Contact your supervisor.'; end if;
  if u.role <> 'promoter' then raise exception 'PROMOTER_ONLY'; end if;
  return u;
end $$;

create or replace function public._require_staff() returns public.app_users
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users;
begin
  select * into u from public.app_users where id = auth.uid();
  if u.id is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if not u.is_active then raise exception 'USER_DISABLED'; end if;
  if u.role not in ('admin','supervisor') then raise exception 'STAFF_ONLY'; end if;
  return u;
end $$;

create or replace function public._require_admin() returns public.app_users
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users;
begin
  u := public._require_staff();
  if u.role <> 'admin' then raise exception 'ADMIN_ONLY'; end if;
  return u;
end $$;

-- ---------------------------------------------------------------------
-- AUDIT LOG (append-only, hash chained)
-- ---------------------------------------------------------------------
create or replace function public._audit_hash(p_prev text, p_at timestamptz, p_actor uuid,
    p_action text, p_entity text, p_entity_id text, p_details jsonb) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(
      coalesce(p_prev,'GENESIS') || '|' ||
      to_char(p_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US') || '|' ||
      coalesce(p_actor::text,'system') || '|' || p_action || '|' ||
      coalesce(p_entity,'') || '|' || coalesce(p_entity_id,'') || '|' ||
      coalesce(p_details::text,'{}'), 'sha256'), 'hex')
$$;

create or replace function public._write_audit(p_actor uuid, p_action text, p_entity text, p_entity_id text, p_details jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_prev text; v_at timestamptz := clock_timestamp(); v_role text;
begin
  perform pg_advisory_xact_lock(hashtext('rio_audit_chain'));
  select hash into v_prev from public.audit_logs order by id desc limit 1;
  select role::text into v_role from public.app_users where id = p_actor;
  insert into public.audit_logs(at, actor_id, actor_role, action, entity, entity_id, details, prev_hash, hash)
  values (v_at, p_actor, coalesce(v_role,'system'), p_action, p_entity, p_entity_id, coalesce(p_details,'{}'::jsonb), v_prev,
          public._audit_hash(v_prev, v_at, p_actor, p_action, p_entity, p_entity_id, coalesce(p_details,'{}'::jsonb)));
end $$;

create or replace function public.write_audit(p_action text, p_entity text, p_entity_id text, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  select public._write_audit(auth.uid(), p_action, p_entity, p_entity_id, p_details)
$$;

-- For the admin-users edge function (service role only)
create or replace function public.write_audit_as(p_actor uuid, p_action text, p_entity text, p_entity_id text, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  select public._write_audit(p_actor, p_action, p_entity, p_entity_id, p_details)
$$;

-- Admin tool: re-computes the chain; returns first broken id (null = intact)
create or replace function public.verify_audit_chain()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_prev text := null; v_n bigint := 0;
begin
  perform public._require_admin();
  for r in select * from public.audit_logs order by id loop
    v_n := v_n + 1;
    if r.prev_hash is distinct from v_prev
       or r.hash <> public._audit_hash(r.prev_hash, r.at, r.actor_id, r.action, r.entity, r.entity_id, r.details) then
      return jsonb_build_object('intact', false, 'broken_at_id', r.id, 'checked', v_n);
    end if;
    v_prev := r.hash;
  end loop;
  return jsonb_build_object('intact', true, 'checked', v_n);
end $$;

-- Block UPDATE / DELETE on append-only tables
create or replace function public._deny_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'IMMUTABLE_RECORD' using detail = TG_TABLE_NAME || ' rows cannot be ' || lower(TG_OP) || 'd';
end $$;

create trigger audit_logs_immutable before update or delete on public.audit_logs
  for each row execute function public._deny_mutation();
create trigger inventory_movements_immutable before update or delete on public.inventory_movements
  for each row execute function public._deny_mutation();
create trigger spins_no_delete before delete on public.spins
  for each row execute function public._deny_mutation();
create trigger sales_no_delete before delete on public.sales
  for each row execute function public._deny_mutation();

-- Spins: the prize and every snapshot field are frozen once written
create or replace function public._guard_spin_update() returns trigger
language plpgsql as $$
begin
  if (new.spin_code, new.sale_id, new.spin_no, new.campaign_id, new.promoter_id, new.biz_date, new.created_at,
      new.strategy, new.pool_id, new.slot_position, new.config_id, new.config_version,
      new.prize_id, new.prize_code, new.prize_name, new.prize_tier, new.prize_cost,
      new.original_prize_id, new.substituted)
     is distinct from
     (old.spin_code, old.sale_id, old.spin_no, old.campaign_id, old.promoter_id, old.biz_date, old.created_at,
      old.strategy, old.pool_id, old.slot_position, old.config_id, old.config_version,
      old.prize_id, old.prize_code, old.prize_name, old.prize_tier, old.prize_cost,
      old.original_prize_id, old.substituted) then
    raise exception 'IMMUTABLE_RECORD' using detail = 'Spin result fields cannot be changed';
  end if;
  if old.redemption_status <> 'pending' and new.redemption_status is distinct from old.redemption_status then
    raise exception 'IMMUTABLE_RECORD' using detail = 'Redemption already finalised';
  end if;
  return new;
end $$;
create trigger spins_guard before update on public.spins
  for each row execute function public._guard_spin_update();

-- Sales: snapshot fields frozen
create or replace function public._guard_sale_update() returns trigger
language plpgsql as $$
begin
  if (new.campaign_id, new.biz_date, new.created_at, new.promoter_id, new.promoter_code, new.promoter_name,
      new.state_id, new.state_name, new.territory_id, new.territory_name, new.tse_id, new.tse_code, new.tse_name,
      new.outlet_id, new.outlet_code, new.outlet_name, new.product_id, new.sku_code, new.product_name, new.quantity)
     is distinct from
     (old.campaign_id, old.biz_date, old.created_at, old.promoter_id, old.promoter_code, old.promoter_name,
      old.state_id, old.state_name, old.territory_id, old.territory_name, old.tse_id, old.tse_code, old.tse_name,
      old.outlet_id, old.outlet_code, old.outlet_name, old.product_id, old.sku_code, old.product_name, old.quantity) then
    raise exception 'IMMUTABLE_RECORD' using detail = 'Sale snapshot fields cannot be changed';
  end if;
  return new;
end $$;
create trigger sales_guard before update on public.sales
  for each row execute function public._guard_sale_update();

-- Generic master-data audit trigger
create or replace function public._audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id text; v_details jsonb;
begin
  if TG_OP = 'DELETE' then
    v_id := coalesce(to_jsonb(old)->>'id', to_jsonb(old)->>'user_id');
    v_details := jsonb_build_object('old', to_jsonb(old));
  elsif TG_OP = 'INSERT' then
    v_id := coalesce(to_jsonb(new)->>'id', to_jsonb(new)->>'user_id');
    v_details := jsonb_build_object('new', to_jsonb(new));
  else
    v_id := coalesce(to_jsonb(new)->>'id', to_jsonb(new)->>'user_id');
    select jsonb_build_object('changed', jsonb_object_agg(n.key, jsonb_build_object('from', o.value, 'to', n.value)))
      into v_details
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o using (key)
     where n.value is distinct from o.value and n.key <> 'updated_at';
    if v_details is null or v_details->'changed' is null then return new; end if;
  end if;
  perform public.write_audit('MASTER_' || TG_OP, TG_TABLE_NAME, v_id, v_details);
  return coalesce(new, old);
end $$;

create or replace function public._touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['states','territories','tses','outlets','app_users','promoters','products','prizes','campaigns']
  loop
    execute format('create trigger %I before update on public.%I for each row execute function public._touch_updated_at()', t||'_touch', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public._audit_row()', t||'_audit', t);
  end loop;
  foreach t in array array['campaign_states','campaign_territory_budgets','campaign_promoters','campaign_products']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public._audit_row()', t||'_audit', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- STOCK LEDGER — the only way stock balances change
-- ---------------------------------------------------------------------
create or replace function public._move_stock(p_promoter uuid, p_prize uuid, p_type public.movement_type,
    p_qty int, p_spin uuid, p_note text, p_reference text default null, p_release_reserved int default 0)
returns int language plpgsql security definer set search_path = public as $$
declare v_after int;
begin
  insert into public.promoter_inventory(promoter_id, prize_id, on_hand, reserved)
  values (p_promoter, p_prize, 0, 0) on conflict do nothing;

  update public.promoter_inventory
     set on_hand = on_hand + p_qty,
         reserved = reserved - p_release_reserved,
         updated_at = now()
   where promoter_id = p_promoter and prize_id = p_prize
  returning on_hand into v_after;

  insert into public.inventory_movements(promoter_id, prize_id, movement_type, qty, on_hand_after, spin_id, performed_by, reference, note)
  values (p_promoter, p_prize, p_type, p_qty, v_after, p_spin, auth.uid(), p_reference, p_note);
  return v_after;
end $$;

-- ---------------------------------------------------------------------
-- FLAGS
-- ---------------------------------------------------------------------
create or replace function public._flag(p_promoter uuid, p_campaign uuid, p_type text, p_severity text,
    p_reason text, p_details jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_key text := coalesce(p_promoter::text,'-') || ':' || p_type || ':' || public.ist_today()::text;
begin
  insert into public.activity_flags(promoter_id, campaign_id, flag_type, severity, reason, details, flag_date, flag_key)
  values (p_promoter, p_campaign, p_type, p_severity, p_reason, coalesce(p_details,'{}'::jsonb), public.ist_today(), v_key)
  on conflict (flag_key) do update
     set occurrences = public.activity_flags.occurrences + 1,
         reason      = excluded.reason,
         details     = excluded.details,
         status      = case when public.activity_flags.status = 'dismissed' then 'dismissed'::public.flag_status else 'open'::public.flag_status end,
         updated_at  = now();
end $$;

create or replace function public._rule(p_campaign uuid, p_key text, p_default numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select (flag_rules->>p_key)::numeric from public.campaigns where id = p_campaign), p_default)
$$;

create or replace function public._check_after_spin(p_spin uuid)
returns void language plpgsql security definer set search_path = public as $$
declare s public.spins; c public.campaigns; v_prev timestamptz; v_n int; v_hv int; v_t time;
begin
  select * into s from public.spins where id = p_spin;
  select * into c from public.campaigns where id = s.campaign_id;

  -- 1. spins too close together
  select max(created_at) into v_prev from public.spins
   where promoter_id = s.promoter_id and id <> s.id and created_at < s.created_at;
  if v_prev is not null and extract(epoch from (s.created_at - v_prev)) < public._rule(c.id,'min_seconds_between_spins',20) then
    perform public._flag(s.promoter_id, c.id, 'rapid_spins', 'medium',
      format('Spins %s seconds apart (minimum expected %s s)', round(extract(epoch from (s.created_at - v_prev))), public._rule(c.id,'min_seconds_between_spins',20)),
      jsonb_build_object('spin_code', s.spin_code));
  end if;

  -- 2. unusually high spin count
  select count(*) into v_n from public.spins where promoter_id = s.promoter_id and biz_date = s.biz_date;
  if v_n > public._rule(c.id,'max_spins_per_day',250) then
    perform public._flag(s.promoter_id, c.id, 'high_spin_count', 'medium',
      format('%s spins today (threshold %s)', v_n, public._rule(c.id,'max_spins_per_day',250)), jsonb_build_object('spins', v_n));
  end if;

  -- 3. concentration of high-value wins
  select count(*) into v_hv from public.spins
   where promoter_id = s.promoter_id and biz_date = s.biz_date
     and prize_cost >= public._rule(c.id,'high_value_cost',100);
  if v_hv > public._rule(c.id,'max_high_value_per_day',3) then
    perform public._flag(s.promoter_id, c.id, 'high_value_concentration', 'high',
      format('%s high-value prizes won today (threshold %s)', v_hv, public._rule(c.id,'max_high_value_per_day',3)),
      jsonb_build_object('high_value_wins', v_hv));
  end if;

  -- 4. outside working hours
  v_t := (s.created_at at time zone 'Asia/Kolkata')::time;
  if v_t < c.work_start or v_t > c.work_end then
    perform public._flag(s.promoter_id, c.id, 'outside_hours', 'low',
      format('Spin at %s IST — outside working hours %s–%s', to_char(v_t,'HH24:MI'), to_char(c.work_start,'HH24:MI'), to_char(c.work_end,'HH24:MI')),
      jsonb_build_object('spin_code', s.spin_code));
  end if;
end $$;

-- Periodic scan (call from dashboards or pg_cron): stale pending handovers
create or replace function public.run_flag_scan()
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0;
begin
  if auth.uid() is not null then perform public._require_staff(); end if;
  for r in
    select s.promoter_id, s.campaign_id, count(*) as n, min(s.spin_code) as first_code
      from public.spins s
     where s.redemption_status = 'pending'
       and s.created_at < now() - make_interval(mins => public._rule(s.campaign_id,'stale_pending_minutes',30)::int)
     group by 1,2
  loop
    perform public._flag(r.promoter_id, r.campaign_id, 'incomplete_transactions', 'medium',
      format('%s spin(s) not marked as handed over after %s min', r.n, public._rule(r.campaign_id,'stale_pending_minutes',30)),
      jsonb_build_object('pending', r.n, 'example_spin', r.first_code));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- >>> supabase/migrations/20260928000300_spin_engine.sql
-- =====================================================================
-- RIO SPIN & WIN — 003 SPIN ENGINE + PROMOTER API
--
-- The phone never decides a prize. It calls:
--   record_sale(sale_id, outlet, sku, qty)   → sale recorded (idempotent)
--   play_spin(sale_id, spin_no)              → server draws prize (idempotent)
--   confirm_handover(spin_id)                → stock deducted, txn completed
--
-- Draw behaviour is driven by campaign settings:
--   draw_strategy : controlled_pool | weighted_random
--   pool_scope    : promoter | outlet | territory | state | campaign
--   oos_mode      : defer | block | substitute
--   config_change_mode : next_pool | regenerate_now
-- =====================================================================

-- ---------------------------------------------------------------------
-- Campaign / config resolution
-- ---------------------------------------------------------------------
create or replace function public._resolve_campaign(p_promoter uuid, p_state uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select c.id
    from public.campaigns c
    join public.campaign_states cs on cs.campaign_id = c.id and cs.state_id = p_state
   where c.status = 'active'
     and (c.start_date is null or c.start_date <= public.ist_today())
     and (c.end_date   is null or c.end_date   >= public.ist_today())
     and (not exists (select 1 from public.campaign_promoters cp where cp.campaign_id = c.id)
          or exists (select 1 from public.campaign_promoters cp where cp.campaign_id = c.id and cp.promoter_id = p_promoter))
   order by c.start_date desc nulls last, c.created_at desc
   limit 1
$$;

-- state-specific config wins over campaign default
create or replace function public._active_config(p_campaign uuid, p_state uuid)
returns public.prize_configs language sql stable security definer set search_path = public as $$
  select * from public.prize_configs
   where campaign_id = p_campaign and is_active
     and (state_id = p_state or state_id is null)
   order by (state_id is null) asc
   limit 1
$$;

create or replace function public._pool_key(p_scope public.pool_scope, s public.sales)
returns text language sql immutable as $$
  select case p_scope
           when 'promoter'  then s.promoter_id::text
           when 'outlet'    then s.outlet_id::text
           when 'territory' then s.territory_id::text
           when 'state'     then s.state_id::text
           else s.campaign_id::text
         end
$$;

-- Create a new pool: expand config into N slots and shuffle with a CSPRNG (gen_random_uuid v4)
create or replace function public._new_pool(p_campaign uuid, p_config uuid, p_scope public.pool_scope, p_key text)
returns public.prize_pools language plpgsql security definer set search_path = public as $$
declare v_pool public.prize_pools; v_no int; v_size int;
begin
  select coalesce(max(pool_no),0) + 1 into v_no from public.prize_pools
   where campaign_id = p_campaign and scope = p_scope and scope_key = p_key;
  select sum(quantity) into v_size from public.prize_config_items where config_id = p_config;
  if coalesce(v_size,0) = 0 then raise exception 'NO_PRIZE_CONFIG' using hint = 'Prize configuration has no prizes.'; end if;

  insert into public.prize_pools(campaign_id, config_id, scope, scope_key, pool_no, size)
  values (p_campaign, p_config, p_scope, p_key, v_no, v_size)
  returning * into v_pool;

  insert into public.prize_pool_slots(pool_id, position, prize_id, unit_cost)
  select v_pool.id, row_number() over (order by gen_random_uuid()), i.prize_id, i.unit_cost
    from public.prize_config_items i
    cross join lateral generate_series(1, i.quantity)
   where i.config_id = p_config and i.quantity > 0;

  perform public.write_audit('POOL_CREATED', 'prize_pools', v_pool.id::text,
    jsonb_build_object('campaign_id', p_campaign, 'config_id', p_config, 'scope', p_scope, 'scope_key', p_key,
                       'pool_no', v_no, 'size', v_size));
  return v_pool;
end $$;

-- Current open pool for scope (creates / regenerates as needed). Caller must hold the scope lock.
create or replace function public._current_pool(c public.campaigns, p_config public.prize_configs, p_key text)
returns public.prize_pools language plpgsql security definer set search_path = public as $$
declare v_pool public.prize_pools;
begin
  select * into v_pool from public.prize_pools
   where campaign_id = c.id and scope = c.pool_scope and scope_key = p_key
     and exhausted_at is null and voided_at is null
   for update;

  if v_pool.id is not null and v_pool.config_id <> p_config.id and c.config_change_mode = 'regenerate_now' then
    update public.prize_pools set voided_at = now(), void_reason = 'prize configuration changed'
     where id = v_pool.id;
    perform public.write_audit('POOL_VOIDED', 'prize_pools', v_pool.id::text,
      jsonb_build_object('reason','config_changed','used', v_pool.used, 'size', v_pool.size));
    v_pool := null;
  end if;

  if v_pool.id is null then
    v_pool := public._new_pool(c.id, p_config.id, c.pool_scope, p_key);
  end if;
  return v_pool;
end $$;

create or replace function public._available(p_promoter uuid, p_prize uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select on_hand - reserved from public.promoter_inventory
                    where promoter_id = p_promoter and prize_id = p_prize), 0)
$$;

-- Returns null if the promoter can spin, otherwise text listing missing prizes.
-- Does NOT reveal order — only which prize TYPES need stock.
create or replace function public._stock_problem(c public.campaigns, p_config public.prize_configs,
    p_promoter uuid, p_key text)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_pool uuid; v_missing text; v_any_ok boolean;
begin
  if not c.track_inventory then return null; end if;

  if c.draw_strategy = 'controlled_pool' then
    select id into v_pool from public.prize_pools
     where campaign_id = c.id and scope = c.pool_scope and scope_key = p_key
       and exhausted_at is null and voided_at is null
       and (config_id = p_config.id or c.config_change_mode = 'next_pool');
  end if;

  with remaining as (
    select distinct s.prize_id from public.prize_pool_slots s
     where v_pool is not null and s.pool_id = v_pool and s.used_at is null
    union
    select i.prize_id from public.prize_config_items i
     where v_pool is null and i.config_id = p_config.id and i.quantity > 0
  )
  select string_agg(p.short_name, ', ' order by p.sort_order) filter (where public._available(p_promoter, r.prize_id) <= 0),
         bool_or(public._available(p_promoter, r.prize_id) > 0)
    into v_missing, v_any_ok
    from remaining r join public.prizes p on p.id = r.prize_id;

  if c.oos_mode = 'block' then
    return v_missing;                                   -- every remaining prize type must be in stock
  elsif not coalesce(v_any_ok,false) then
    return coalesce(v_missing, 'all prizes');           -- defer/substitute: need at least one
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- WORK CONTEXT (session memory mirrored server-side)
-- ---------------------------------------------------------------------
create or replace function public.set_work_context(p_outlet_id uuid, p_device_ref text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; r record; v_campaign uuid; c public.campaigns;
begin
  u := public._require_promoter();
  select o.id outlet_id, o.outlet_code, o.name outlet_name, o.area, o.city,
         t.id tse_id, t.name tse_name, tr.id territory_id, tr.name territory_name, st.id state_id, st.name state_name
    into r
    from public.outlets o
    join public.tses t on t.id = o.tse_id
    join public.territories tr on tr.id = t.territory_id
    join public.states st on st.id = tr.state_id
   where o.id = p_outlet_id and o.status = 'active';
  if r.outlet_id is null then raise exception 'OUTLET_NOT_ACTIVE' using hint = 'This outlet is not in the approved outlet master.'; end if;

  v_campaign := public._resolve_campaign(u.id, r.state_id);
  select * into c from public.campaigns where id = v_campaign;

  insert into public.promoter_sessions(promoter_id, work_date, campaign_id, state_id, territory_id, tse_id, outlet_id, device_ref)
  values (u.id, public.ist_today(), v_campaign, r.state_id, r.territory_id, r.tse_id, r.outlet_id, p_device_ref)
  on conflict (promoter_id, work_date) do update
     set campaign_id = excluded.campaign_id, state_id = excluded.state_id, territory_id = excluded.territory_id,
         tse_id = excluded.tse_id, outlet_id = excluded.outlet_id, device_ref = coalesce(excluded.device_ref, public.promoter_sessions.device_ref),
         updated_at = now();

  perform public.write_audit('OUTLET_SELECTED', 'outlets', r.outlet_id::text,
    jsonb_build_object('outlet_code', r.outlet_code, 'tse', r.tse_name, 'device_ref', p_device_ref));

  return jsonb_build_object(
    'outlet', to_jsonb(r),
    'campaign', case when c.id is null then null else jsonb_build_object(
        'id', c.id, 'code', c.code, 'name', c.name, 'sound_default', c.sound_default,
        'spins_per_sale', c.spins_per_sale, 'max_quantity_per_sale', c.max_quantity_per_sale,
        'validation_rules', c.validation_rules, 'capture_consumer', c.capture_consumer) end);
end $$;

-- ---------------------------------------------------------------------
-- RECORD SALE
-- ---------------------------------------------------------------------
create or replace function public.record_sale(
    p_sale_id uuid, p_outlet_id uuid, p_product_id uuid, p_quantity int,
    p_device_ref text default null, p_validation jsonb default '{}'::jsonb,
    p_client_time timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u public.app_users; pr public.promoters; s public.sales; c public.campaigns; cfg public.prize_configs;
  r record; p public.products; v_campaign uuid; v_problem text; v_used numeric; v_budget numeric;
  v_key text; k text; v text;
begin
  u := public._require_promoter();

  -- idempotent replay
  select * into s from public.sales where id = p_sale_id;
  if s.id is not null then
    if s.promoter_id <> u.id then raise exception 'SALE_NOT_FOUND'; end if;
    return jsonb_build_object('sale_id', s.id, 'status', s.status, 'spins_allowed', s.spins_allowed,
                              'spins_used', s.spins_used, 'replayed', true);
  end if;

  -- one customer at a time: a won prize must be handed over first
  if exists (select 1 from public.spins where promoter_id = u.id and redemption_status = 'pending') then
    raise exception 'PENDING_HANDOVER' using hint = 'Hand over the previous prize before starting a new sale.';
  end if;

  select * into pr from public.promoters where user_id = u.id;
  if pr.user_id is null then raise exception 'PROMOTER_PROFILE_MISSING'; end if;

  select o.id outlet_id, o.outlet_code, o.name outlet_name, o.area, o.city, o.distributor,
         t.id tse_id, t.code tse_code, t.name tse_name,
         tr.id territory_id, tr.name territory_name, st.id state_id, st.name state_name
    into r
    from public.outlets o
    join public.tses t on t.id = o.tse_id
    join public.territories tr on tr.id = t.territory_id
    join public.states st on st.id = tr.state_id
   where o.id = p_outlet_id and o.status = 'active';
  if r.outlet_id is null then raise exception 'OUTLET_NOT_ACTIVE'; end if;

  v_campaign := public._resolve_campaign(u.id, r.state_id);
  if v_campaign is null then raise exception 'NO_ACTIVE_CAMPAIGN' using hint = 'No active campaign covers this outlet''s state.'; end if;
  select * into c from public.campaigns where id = v_campaign;

  select * into p from public.products where id = p_product_id and is_active;
  if p.id is null then raise exception 'PRODUCT_NOT_ALLOWED'; end if;
  if exists (select 1 from public.campaign_products where campaign_id = c.id)
     and not exists (select 1 from public.campaign_products where campaign_id = c.id and product_id = p.id) then
    raise exception 'PRODUCT_NOT_ALLOWED' using hint = 'This SKU is not part of the campaign.';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > c.max_quantity_per_sale then
    raise exception 'INVALID_QUANTITY' using hint = format('Quantity must be 1–%s', c.max_quantity_per_sale);
  end if;

  -- optional validation (only when admin enables it)
  for k, v in select key, value #>> '{}' from jsonb_each(c.validation_rules) loop
    if v = 'required' and coalesce(nullif(p_validation->>k, ''), '') = '' then
      raise exception 'VALIDATION_REQUIRED' using detail = k, hint = format('%s is required for this campaign', replace(k,'_',' '));
    end if;
  end loop;

  -- budget control
  if c.enforce_budget then
    select coalesce(sum(prize_cost),0) into v_used from public.spins
     where campaign_id = c.id and redemption_status <> 'not_redeemed';
    if c.total_budget is not null and v_used >= c.total_budget then
      raise exception 'BUDGET_EXHAUSTED' using hint = 'Campaign budget fully used.';
    end if;
    if c.daily_budget is not null then
      select coalesce(sum(prize_cost),0) into v_used from public.spins
       where campaign_id = c.id and biz_date = public.ist_today() and redemption_status <> 'not_redeemed';
      if v_used >= c.daily_budget then raise exception 'BUDGET_EXHAUSTED' using hint = 'Today''s budget fully used.'; end if;
    end if;
    select budget into v_budget from public.campaign_states where campaign_id = c.id and state_id = r.state_id;
    if v_budget is not null then
      select coalesce(sum(sp.prize_cost),0) into v_used from public.spins sp join public.sales sa on sa.id = sp.sale_id
       where sp.campaign_id = c.id and sa.state_id = r.state_id and sp.redemption_status <> 'not_redeemed';
      if v_used >= v_budget then raise exception 'BUDGET_EXHAUSTED' using hint = 'State budget fully used.'; end if;
    end if;
    select budget into v_budget from public.campaign_territory_budgets where campaign_id = c.id and territory_id = r.territory_id;
    if v_budget is not null then
      select coalesce(sum(sp.prize_cost),0) into v_used from public.spins sp join public.sales sa on sa.id = sp.sale_id
       where sp.campaign_id = c.id and sa.territory_id = r.territory_id and sp.redemption_status <> 'not_redeemed';
      if v_used >= v_budget then raise exception 'BUDGET_EXHAUSTED' using hint = 'Territory budget fully used.'; end if;
    end if;
  end if;

  cfg := public._active_config(c.id, r.state_id);
  if cfg.id is null then raise exception 'NO_PRIZE_CONFIG' using hint = 'Admin has not configured prizes for this campaign/state.'; end if;

  -- stock readiness (checked before the customer spins)
  s.promoter_id := u.id; s.outlet_id := r.outlet_id; s.territory_id := r.territory_id; s.state_id := r.state_id; s.campaign_id := c.id;
  v_key := public._pool_key(c.pool_scope, s);
  v_problem := public._stock_problem(c, cfg, u.id, v_key);
  if v_problem is not null then
    raise exception 'OUT_OF_STOCK' using detail = v_problem, hint = 'Replenish prize stock: ' || v_problem;
  end if;

  -- an older sale that was never spun is superseded
  update public.sales set status = 'cancelled', cancelled_reason = 'superseded by new sale'
   where promoter_id = u.id and status = 'open' and spins_used = 0;

  insert into public.sales(id, campaign_id, biz_date, client_created_at,
      promoter_id, promoter_code, promoter_name, promoter_type,
      state_id, state_name, territory_id, territory_name, tse_id, tse_code, tse_name,
      outlet_id, outlet_code, outlet_name, outlet_area, outlet_city, distributor,
      product_id, sku_code, product_name, quantity, spins_allowed, validation, device_ref)
  values (p_sale_id, c.id, public.ist_today(), p_client_time,
      u.id, pr.promoter_code, u.full_name, pr.promoter_type,
      r.state_id, r.state_name, r.territory_id, r.territory_name, r.tse_id, r.tse_code, r.tse_name,
      r.outlet_id, r.outlet_code, r.outlet_name, r.area, r.city, r.distributor,
      p.id, p.sku_code, p.name, p_quantity, c.spins_per_sale, coalesce(p_validation,'{}'::jsonb), p_device_ref);

  perform public.write_audit('SALE_RECORDED', 'sales', p_sale_id::text,
    jsonb_build_object('outlet_code', r.outlet_code, 'tse_code', r.tse_code, 'sku', p.sku_code,
                       'qty', p_quantity, 'campaign', c.code, 'device_ref', p_device_ref));

  return jsonb_build_object('sale_id', p_sale_id, 'status', 'open', 'spins_allowed', c.spins_per_sale,
                            'spins_used', 0, 'replayed', false);
end $$;

-- ---------------------------------------------------------------------
-- PLAY SPIN — the draw
-- ---------------------------------------------------------------------
create or replace function public._spin_json(p_spin uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'spin_id', s.id, 'spin_code', s.spin_code, 'sale_id', s.sale_id, 'spin_no', s.spin_no,
    'redemption_status', s.redemption_status, 'created_at', s.created_at,
    'prize', jsonb_build_object('id', p.id, 'code', p.code, 'name', s.prize_name, 'short_name', p.short_name,
       'tier', s.prize_tier, 'wheel_label', p.wheel_label, 'win_title', p.win_title,
       'win_subtitle', p.win_subtitle, 'image_url', p.image_url))
  from public.spins s join public.prizes p on p.id = s.prize_id
  where s.id = p_spin
$$;

create or replace function public.play_spin(p_sale_id uuid, p_spin_no int default 1, p_device_ref text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u public.app_users; s public.sales; c public.campaigns; cfg public.prize_configs; pool public.prize_pools;
  v_existing uuid; v_key text; v_spin_id uuid := gen_random_uuid();
  v_pos int; v_prize uuid; v_cost numeric; v_orig uuid; v_sub boolean := false;
  d record; pz public.prizes; v_total numeric; v_r numeric; v_acc numeric := 0; it record;
  v_inv_status text;
begin
  u := public._require_promoter();

  select * into s from public.sales where id = p_sale_id for update;
  if s.id is null or s.promoter_id <> u.id then raise exception 'SALE_NOT_FOUND'; end if;

  -- idempotency: the same (sale, spin_no) ALWAYS returns the same result
  select id into v_existing from public.spins where sale_id = s.id and spin_no = p_spin_no;
  if v_existing is not null then return public._spin_json(v_existing) || jsonb_build_object('replayed', true); end if;

  if s.status = 'cancelled' then raise exception 'SALE_CANCELLED'; end if;
  if p_spin_no < 1 or p_spin_no <> s.spins_used + 1 or p_spin_no > s.spins_allowed then
    raise exception 'NO_SPINS_LEFT' using hint = 'This sale has already used its spin.';
  end if;

  select * into c from public.campaigns where id = s.campaign_id;
  if c.status <> 'active' then raise exception 'CAMPAIGN_NOT_ACTIVE'; end if;
  cfg := public._active_config(c.id, s.state_id);
  if cfg.id is null then raise exception 'NO_PRIZE_CONFIG'; end if;
  v_key := public._pool_key(c.pool_scope, s);

  if c.draw_strategy = 'controlled_pool' then
    -- serialise draws within one pool scope
    perform pg_advisory_xact_lock(hashtext('rio_pool:' || c.id::text || ':' || c.pool_scope::text || ':' || v_key));
    pool := public._current_pool(c, cfg, v_key);

    if not c.track_inventory then
      select position, prize_id, unit_cost into v_pos, v_prize, v_cost
        from public.prize_pool_slots where pool_id = pool.id and used_at is null
       order by position limit 1 for update;

    elsif c.oos_mode = 'defer' then
      -- next slot whose prize the promoter physically holds; earlier out-of-stock slots stay for later
      select sl.position, sl.prize_id, sl.unit_cost into v_pos, v_prize, v_cost
        from public.prize_pool_slots sl
       where sl.pool_id = pool.id and sl.used_at is null
         and public._available(u.id, sl.prize_id) > 0
       order by sl.position limit 1 for update;
      -- log newly deferred slots (prize type only, never position)
      for d in
        update public.prize_pool_slots sl set deferred_at = now()
         where sl.pool_id = pool.id and sl.used_at is null and sl.deferred_at is null
           and sl.position < coalesce(v_pos, 2147483647)
        returning sl.prize_id
      loop
        perform public.write_audit('PRIZE_DEFERRED', 'prize_pools', pool.id::text,
          jsonb_build_object('prize_id', d.prize_id, 'promoter_id', u.id, 'sale_id', s.id, 'reason', 'promoter out of stock'));
      end loop;

    else
      select position, prize_id, unit_cost into v_pos, v_prize, v_cost
        from public.prize_pool_slots where pool_id = pool.id and used_at is null
       order by position limit 1 for update;
      if v_pos is not null and public._available(u.id, v_prize) <= 0 then
        if c.oos_mode = 'block' then
          raise exception 'OUT_OF_STOCK' using hint = 'Replenish prize stock before continuing.';
        end if;
        -- substitute: closest in-stock prize not costlier than the original, else cheapest available
        v_orig := v_prize;
        select i.prize_id, i.unit_cost into v_prize, v_cost
          from public.prize_config_items i
         where i.config_id = cfg.id and i.prize_id <> v_orig and public._available(u.id, i.prize_id) > 0
         order by (i.unit_cost <= v_cost) desc,
                  case when i.unit_cost <= v_cost then -i.unit_cost else i.unit_cost end
         limit 1;
        if v_prize is null then raise exception 'OUT_OF_STOCK'; end if;
        v_sub := true;
      end if;
    end if;

    if v_pos is null then
      raise exception 'OUT_OF_STOCK' using hint = 'No prize available in stock for the remaining pool.';
    end if;

    update public.prize_pool_slots set used_at = now(), spin_id = v_spin_id
     where pool_id = pool.id and position = v_pos;
    update public.prize_pools set used = used + 1,
           exhausted_at = case when used + 1 >= size then now() else null end
     where id = pool.id;

  else
    -- weighted_random: independent draw weighted by configured quantities, restricted to in-stock prizes
    select sum(i.quantity) into v_total from public.prize_config_items i
     where i.config_id = cfg.id and i.quantity > 0
       and (not c.track_inventory or public._available(u.id, i.prize_id) > 0);
    if coalesce(v_total,0) = 0 then raise exception 'OUT_OF_STOCK'; end if;
    v_r := (('x' || encode(extensions.gen_random_bytes(6), 'hex'))::bit(48)::bigint)::numeric / 281474976710656 * v_total;
    for it in select i.prize_id, i.unit_cost, i.quantity from public.prize_config_items i
               where i.config_id = cfg.id and i.quantity > 0
                 and (not c.track_inventory or public._available(u.id, i.prize_id) > 0)
               order by i.prize_id loop
      v_acc := v_acc + it.quantity;
      if v_r < v_acc then v_prize := it.prize_id; v_cost := it.unit_cost; exit; end if;
    end loop;
  end if;

  select * into pz from public.prizes where id = v_prize;

  -- reserve the physical unit (deducted on handover)
  if c.track_inventory then
    update public.promoter_inventory set reserved = reserved + 1, updated_at = now()
     where promoter_id = u.id and prize_id = v_prize and on_hand - reserved > 0;
    if not found then raise exception 'OUT_OF_STOCK'; end if;
    v_inv_status := 'reserved';
  else
    v_inv_status := 'not_tracked';
  end if;

  insert into public.spins(id, spin_code, sale_id, spin_no, campaign_id, promoter_id, biz_date,
      strategy, pool_id, slot_position, config_id, config_version,
      prize_id, prize_code, prize_name, prize_tier, prize_cost, original_prize_id, substituted,
      inventory_status, device_ref)
  values (v_spin_id,
      'SPN' || to_char(public.ist_now(),'YYMMDD') || '-' || lpad(nextval('public.spin_code_seq')::text, 6, '0'),
      s.id, p_spin_no, c.id, u.id, public.ist_today(),
      c.draw_strategy, pool.id, v_pos, cfg.id, cfg.version,
      pz.id, pz.code, pz.name, pz.tier, v_cost, v_orig, v_sub,
      v_inv_status, coalesce(p_device_ref, s.device_ref));

  update public.sales set spins_used = spins_used + 1, status = 'spun' where id = s.id;

  perform public.write_audit('SPIN', 'spins', v_spin_id::text,
    jsonb_build_object('sale_id', s.id, 'prize', pz.code, 'cost', v_cost, 'strategy', c.draw_strategy,
                       'pool_id', pool.id, 'pool_no', pool.pool_no, 'config_version', cfg.version,
                       'substituted', v_sub, 'original_prize_id', v_orig, 'outlet_code', s.outlet_code));
  if v_sub then
    perform public.write_audit('PRIZE_SUBSTITUTED', 'spins', v_spin_id::text,
      jsonb_build_object('original_prize_id', v_orig, 'awarded_prize_id', v_prize, 'reason', 'promoter out of stock'));
  end if;

  perform public._check_after_spin(v_spin_id);
  return public._spin_json(v_spin_id) || jsonb_build_object('replayed', false);
end $$;

-- ---------------------------------------------------------------------
-- PRIZE HANDED OVER
-- ---------------------------------------------------------------------
create or replace function public.confirm_handover(p_spin_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; sp public.spins; v_left int; v_thr int; v_name text; v_min numeric;
begin
  u := public._require_promoter();
  select * into sp from public.spins where id = p_spin_id for update;
  if sp.id is null or sp.promoter_id <> u.id then raise exception 'SPIN_NOT_FOUND'; end if;
  if sp.redemption_status = 'handed_over' then
    return jsonb_build_object('ok', true, 'replayed', true);
  end if;
  if sp.redemption_status <> 'pending' then raise exception 'SPIN_ALREADY_RESOLVED'; end if;

  update public.spins set redemption_status = 'handed_over', handed_over_at = now(),
         inventory_status = case when inventory_status = 'reserved' then 'deducted' else inventory_status end
   where id = sp.id;

  if sp.inventory_status = 'reserved' then
    v_left := public._move_stock(u.id, sp.prize_id, 'award', -1, sp.id, 'Prize handed over ' || sp.spin_code, sp.spin_code, 1);
  else
    v_left := null;
  end if;

  update public.sales set status = 'completed'
   where id = sp.sale_id and spins_used >= spins_allowed
     and not exists (select 1 from public.spins x where x.sale_id = sp.sale_id and x.redemption_status = 'pending');

  perform public.write_audit('PRIZE_HANDED_OVER', 'spins', sp.id::text,
    jsonb_build_object('spin_code', sp.spin_code, 'prize', sp.prize_code, 'on_hand_after', v_left));

  v_min := extract(epoch from (now() - sp.created_at)) / 60;
  if v_min > public._rule(sp.campaign_id, 'slow_handover_minutes', 20) then
    perform public._flag(sp.promoter_id, sp.campaign_id, 'abnormal_redemption', 'low',
      format('Prize %s confirmed %s min after spin', sp.prize_name, round(v_min)), jsonb_build_object('spin_code', sp.spin_code));
  end if;

  select low_stock_threshold, short_name into v_thr, v_name from public.prizes where id = sp.prize_id;
  return jsonb_build_object('ok', true, 'replayed', false, 'prize_left', v_left,
                            'low_stock', v_left is not null and v_left <= v_thr, 'prize_short_name', v_name);
end $$;

-- Pending spin to resume after refresh / app restart (same result, never a new draw)
create or replace function public.my_pending_spin()
returns jsonb language sql stable security definer set search_path = public as $$
  select public._spin_json(id) from public.spins
   where promoter_id = auth.uid() and redemption_status = 'pending'
   order by created_at limit 1
$$;

-- Promoter may abandon a sale ONLY before it has been spun
create or replace function public.cancel_open_sale(p_sale_id uuid, p_reason text default 'customer left')
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; s public.sales; v_n int;
begin
  u := public._require_promoter();
  select * into s from public.sales where id = p_sale_id for update;
  if s.id is null or s.promoter_id <> u.id then raise exception 'SALE_NOT_FOUND'; end if;
  if s.spins_used > 0 then raise exception 'SALE_ALREADY_SPUN' using hint = 'A spin result is permanent and cannot be cancelled.'; end if;
  if s.status = 'cancelled' then return jsonb_build_object('ok', true); end if;
  update public.sales set status = 'cancelled', cancelled_reason = left(coalesce(p_reason,'cancelled'), 200) where id = s.id;
  perform public.write_audit('SALE_CANCELLED', 'sales', s.id::text, jsonb_build_object('reason', p_reason));

  select count(*) into v_n from public.sales where promoter_id = u.id and biz_date = public.ist_today() and status = 'cancelled';
  if v_n > public._rule(s.campaign_id, 'max_cancelled_per_day', 5) then
    perform public._flag(u.id, s.campaign_id, 'excess_cancellations', 'medium',
      format('%s cancelled/incomplete sales today', v_n), jsonb_build_object('cancelled', v_n));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- PROMOTER HOME (one round-trip for the dashboard)
-- ---------------------------------------------------------------------
create or replace function public.get_promoter_home()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u public.app_users; pr public.promoters; v_today jsonb; v_stock jsonb; v_session jsonb;
begin
  u := public._require_promoter();
  select * into pr from public.promoters where user_id = u.id;

  select jsonb_build_object(
      'sales', (select count(*) from public.sales where promoter_id = u.id and biz_date = public.ist_today() and status <> 'cancelled'),
      'units', (select coalesce(sum(quantity),0) from public.sales where promoter_id = u.id and biz_date = public.ist_today() and status <> 'cancelled'),
      'spins', count(*),
      'prizes_given', count(*) filter (where redemption_status = 'handed_over'),
      'prize_cost', coalesce(sum(prize_cost) filter (where redemption_status <> 'not_redeemed'),0),
      'avg_cost', round(coalesce(avg(prize_cost) filter (where redemption_status <> 'not_redeemed'),0), 2))
    into v_today
    from public.spins where promoter_id = u.id and biz_date = public.ist_today();

  select coalesce(jsonb_agg(jsonb_build_object(
      'prize_id', p.id, 'name', p.name, 'short_name', p.short_name, 'tier', p.tier,
      'on_hand', coalesce(i.on_hand,0), 'reserved', coalesce(i.reserved,0),
      'threshold', p.low_stock_threshold,
      'low', coalesce(i.on_hand,0) <= p.low_stock_threshold) order by p.sort_order), '[]'::jsonb)
    into v_stock
    from public.prizes p
    left join public.promoter_inventory i on i.prize_id = p.id and i.promoter_id = u.id
   where p.is_active;

  select to_jsonb(x) into v_session from (
    select ps.work_date, ps.campaign_id, c.name campaign_name, ps.state_id, ps.territory_id, ps.tse_id, ps.outlet_id
      from public.promoter_sessions ps left join public.campaigns c on c.id = ps.campaign_id
     where ps.promoter_id = u.id and ps.work_date = public.ist_today()) x;

  return jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'name', u.full_name, 'login_id', u.login_id,
                               'promoter_code', pr.promoter_code, 'promoter_type', pr.promoter_type),
    'today', v_today, 'stock', v_stock, 'session', v_session,
    'pending_spin', public.my_pending_spin(),
    'biz_date', public.ist_today());
end $$;

-- ---------------------------------------------------------------------
-- OUTLET NOT LISTED
-- ---------------------------------------------------------------------
create or replace function public.submit_outlet_request(p_name text, p_area text, p_city text,
    p_ref_code text default null, p_suggested_tse uuid default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; v_id uuid; v_n int; v_campaign uuid;
begin
  u := public._require_promoter();
  if coalesce(trim(p_name),'') = '' then raise exception 'OUTLET_NAME_REQUIRED'; end if;
  select campaign_id into v_campaign from public.promoter_sessions where promoter_id = u.id and work_date = public.ist_today();
  insert into public.outlet_requests(promoter_id, campaign_id, outlet_name, area, city, ref_code, suggested_tse_id, note)
  values (u.id, v_campaign, trim(p_name), p_area, p_city, p_ref_code, p_suggested_tse, p_note)
  returning id into v_id;
  perform public.write_audit('OUTLET_REQUESTED', 'outlet_requests', v_id::text,
    jsonb_build_object('name', p_name, 'area', p_area, 'city', p_city, 'suggested_tse', p_suggested_tse));

  select count(*) into v_n from public.outlet_requests
   where promoter_id = u.id and (created_at at time zone 'Asia/Kolkata')::date = public.ist_today();
  if v_n > coalesce(public._rule(v_campaign, 'max_outlet_requests_per_day', 3), 3) then
    perform public._flag(u.id, v_campaign, 'repeated_outlet_not_listed', 'medium',
      format('%s "Outlet Not Listed" requests today', v_n), jsonb_build_object('requests', v_n));
  end if;
  return jsonb_build_object('request_id', v_id, 'status', 'pending');
end $$;

-- >>> supabase/migrations/20260928000400_staff_admin.sql
-- =====================================================================
-- RIO SPIN & WIN — 004 SUPERVISOR / ADMIN API + REPORTING
-- =====================================================================

-- ---------------------------------------------------------------------
-- STOCK: issue / return / damaged / missing / adjustment
-- ---------------------------------------------------------------------
create or replace function public.adjust_stock(p_promoter uuid, p_prize uuid, p_type public.movement_type,
    p_qty int, p_note text default null, p_reference text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; v_delta int; v_inv public.promoter_inventory; v_after int; v_campaign uuid;
begin
  u := public._require_staff();
  if not public.can_see_promoter(p_promoter) then raise exception 'NOT_YOUR_PROMOTER'; end if;
  if p_type = 'award' then raise exception 'INVALID_MOVEMENT' using hint = 'Awards are recorded automatically on handover.'; end if;
  if p_type = 'adjustment' and u.role <> 'admin' then raise exception 'ADMIN_ONLY'; end if;
  if p_qty is null or p_qty = 0 then raise exception 'INVALID_QUANTITY'; end if;
  if p_type <> 'adjustment' and p_qty < 0 then raise exception 'INVALID_QUANTITY'; end if;

  v_delta := case p_type when 'issue' then p_qty when 'adjustment' then p_qty else -p_qty end;

  select * into v_inv from public.promoter_inventory where promoter_id = p_promoter and prize_id = p_prize for update;
  if coalesce(v_inv.on_hand,0) + v_delta < coalesce(v_inv.reserved,0) then
    raise exception 'INSUFFICIENT_STOCK' using hint = format('Promoter holds %s (%s reserved for pending prizes)', coalesce(v_inv.on_hand,0), coalesce(v_inv.reserved,0));
  end if;

  v_after := public._move_stock(p_promoter, p_prize, p_type, v_delta, null, p_note, p_reference, 0);
  perform public.write_audit('STOCK_' || upper(p_type::text), 'promoter_inventory', p_promoter::text || ':' || p_prize::text,
    jsonb_build_object('promoter_id', p_promoter, 'prize_id', p_prize, 'qty', v_delta, 'on_hand_after', v_after, 'note', p_note));

  if p_type in ('damaged','missing') then
    select campaign_id into v_campaign from public.promoter_sessions where promoter_id = p_promoter order by work_date desc limit 1;
    perform public._flag(p_promoter, v_campaign, 'stock_discrepancy', case when p_type = 'missing' then 'high' else 'medium' end,
      format('%s unit(s) of %s recorded as %s', p_qty, (select short_name from public.prizes where id = p_prize), p_type),
      jsonb_build_object('prize_id', p_prize, 'qty', p_qty, 'type', p_type));
  end if;
  return jsonb_build_object('ok', true, 'on_hand', v_after);
end $$;

-- Issue a whole kit (e.g. one pool's worth) in one call
create or replace function public.issue_stock_kit(p_promoter uuid, p_items jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it record; v_res jsonb := '[]'::jsonb;
begin
  perform public._require_staff();
  for it in select (e->>'prize_id')::uuid prize_id, (e->>'qty')::int qty from jsonb_array_elements(p_items) e loop
    if it.qty > 0 then
      v_res := v_res || jsonb_build_array(public.adjust_stock(p_promoter, it.prize_id, 'issue', it.qty, p_note) || jsonb_build_object('prize_id', it.prize_id));
    end if;
  end loop;
  return v_res;
end $$;

-- Supervisor resolution of a stuck (pending) spin
create or replace function public.resolve_spin(p_spin_id uuid, p_action text, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; sp public.spins;
begin
  u := public._require_staff();
  select * into sp from public.spins where id = p_spin_id for update;
  if sp.id is null or not public.can_see_promoter(sp.promoter_id) then raise exception 'SPIN_NOT_FOUND'; end if;
  if sp.redemption_status <> 'pending' then raise exception 'SPIN_ALREADY_RESOLVED'; end if;
  if coalesce(trim(p_note),'') = '' then raise exception 'NOTE_REQUIRED'; end if;

  if p_action = 'handed_over' then
    update public.spins set redemption_status = 'handed_over', handed_over_at = now(), resolved_by = u.id, resolution_note = p_note,
           inventory_status = case when inventory_status = 'reserved' then 'deducted' else inventory_status end
     where id = sp.id;
    if sp.inventory_status = 'reserved' then
      perform public._move_stock(sp.promoter_id, sp.prize_id, 'award', -1, sp.id, 'Resolved by supervisor: ' || p_note, sp.spin_code, 1);
    end if;
  elsif p_action = 'not_redeemed' then
    update public.spins set redemption_status = 'not_redeemed', resolved_by = u.id, resolution_note = p_note,
           inventory_status = case when inventory_status = 'reserved' then 'released' else inventory_status end
     where id = sp.id;
    if sp.inventory_status = 'reserved' then
      update public.promoter_inventory set reserved = reserved - 1, updated_at = now()
       where promoter_id = sp.promoter_id and prize_id = sp.prize_id;
    end if;
  else
    raise exception 'INVALID_ACTION';
  end if;
  update public.sales set status = 'completed' where id = sp.sale_id
     and not exists (select 1 from public.spins x where x.sale_id = sp.sale_id and x.redemption_status = 'pending');
  perform public.write_audit('SPIN_RESOLVED', 'spins', sp.id::text, jsonb_build_object('action', p_action, 'note', p_note, 'spin_code', sp.spin_code));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- OUTLET REQUEST REVIEW
-- ---------------------------------------------------------------------
create or replace function public.review_outlet_request(p_request_id uuid, p_approve boolean,
    p_tse_id uuid default null, p_outlet_code text default null, p_note text default null,
    p_name text default null, p_area text default null, p_city text default null, p_distributor text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; rq public.outlet_requests; v_outlet uuid; v_code text;
begin
  u := public._require_staff();
  if u.role = 'supervisor' and not u.can_approve_outlets then raise exception 'NOT_AUTHORISED' using hint = 'You are not authorised to approve outlets.'; end if;
  select * into rq from public.outlet_requests where id = p_request_id for update;
  if rq.id is null or not public.can_see_promoter(rq.promoter_id) then raise exception 'REQUEST_NOT_FOUND'; end if;
  if rq.status <> 'pending' then raise exception 'REQUEST_ALREADY_REVIEWED'; end if;

  if p_approve then
    if coalesce(p_tse_id, rq.suggested_tse_id) is null then raise exception 'TSE_REQUIRED'; end if;
    v_code := coalesce(nullif(trim(p_outlet_code),''), nullif(trim(rq.ref_code),''),
                       'NEW-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)));
    if exists (select 1 from public.outlets where outlet_code = v_code) then raise exception 'OUTLET_CODE_EXISTS'; end if;
    insert into public.outlets(tse_id, outlet_code, name, area, city, distributor, source)
    values (coalesce(p_tse_id, rq.suggested_tse_id), v_code, coalesce(nullif(p_name,''), rq.outlet_name),
            coalesce(p_area, rq.area), coalesce(p_city, rq.city), p_distributor, 'request')
    returning id into v_outlet;
  end if;

  update public.outlet_requests set status = case when p_approve then 'approved'::public.request_status else 'rejected'::public.request_status end,
         reviewed_by = u.id, reviewed_at = now(), review_note = p_note, outlet_id = v_outlet
   where id = rq.id;
  perform public.write_audit(case when p_approve then 'OUTLET_REQUEST_APPROVED' else 'OUTLET_REQUEST_REJECTED' end,
    'outlet_requests', rq.id::text, jsonb_build_object('outlet_id', v_outlet, 'outlet_code', v_code, 'note', p_note));
  return jsonb_build_object('ok', true, 'outlet_id', v_outlet, 'outlet_code', v_code);
end $$;

-- ---------------------------------------------------------------------
-- FLAGS
-- ---------------------------------------------------------------------
create or replace function public.review_flag(p_flag_id uuid, p_status public.flag_status, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; f public.activity_flags;
begin
  u := public._require_staff();
  select * into f from public.activity_flags where id = p_flag_id for update;
  if f.id is null or (f.promoter_id is not null and not public.can_see_promoter(f.promoter_id)) then raise exception 'FLAG_NOT_FOUND'; end if;
  update public.activity_flags set status = p_status, reviewed_by = u.id, reviewed_at = now(), review_note = p_note, updated_at = now()
   where id = f.id;
  perform public.write_audit('FLAG_REVIEWED', 'activity_flags', f.id::text, jsonb_build_object('status', p_status, 'note', p_note));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.raise_flag(p_promoter uuid, p_reason text, p_severity text default 'medium')
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; v_id uuid; v_campaign uuid;
begin
  u := public._require_staff();
  if not public.can_see_promoter(p_promoter) then raise exception 'NOT_YOUR_PROMOTER'; end if;
  select campaign_id into v_campaign from public.promoter_sessions where promoter_id = p_promoter order by work_date desc limit 1;
  insert into public.activity_flags(promoter_id, campaign_id, flag_type, severity, reason, flag_date, source, raised_by)
  values (p_promoter, v_campaign, 'manual', p_severity, p_reason, public.ist_today(), 'manual', u.id) returning id into v_id;
  perform public.write_audit('FLAG_RAISED', 'activity_flags', v_id::text, jsonb_build_object('promoter_id', p_promoter, 'reason', p_reason));
  return jsonb_build_object('ok', true, 'flag_id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- PRIZE CONFIGURATION (versioned, with economics check)
-- p_items: [{"prize_id": "...", "quantity": 152, "unit_cost": 5}, ...]
-- ---------------------------------------------------------------------
create or replace function public.save_prize_config(p_campaign uuid, p_state uuid, p_pool_size int,
    p_items jsonb, p_override boolean default false, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; c public.campaigns; v_qty int; v_total numeric; v_avg numeric; v_ver int; v_id uuid; v_prev uuid;
begin
  u := public._require_admin();
  select * into c from public.campaigns where id = p_campaign;
  if c.id is null then raise exception 'CAMPAIGN_NOT_FOUND'; end if;
  if p_pool_size is null or p_pool_size < 1 then raise exception 'INVALID_POOL_SIZE'; end if;

  select coalesce(sum((e->>'quantity')::int),0), coalesce(sum((e->>'quantity')::int * (e->>'unit_cost')::numeric),0)
    into v_qty, v_total from jsonb_array_elements(p_items) e;
  if v_qty <> p_pool_size then
    raise exception 'POOL_SIZE_MISMATCH' using hint = format('Prize quantities add up to %s but pool size is %s', v_qty, p_pool_size);
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) e where (e->>'quantity')::int < 0 or (e->>'unit_cost')::numeric < 0) then
    raise exception 'INVALID_ITEMS';
  end if;
  v_avg := round(v_total / p_pool_size, 4);

  if v_avg > c.target_cost_per_spin then
    if not coalesce(p_override,false) then
      raise exception 'COST_ABOVE_TARGET' using detail = v_avg::text,
        hint = format('Average cost per spin ₹%s exceeds the ₹%s campaign target.', round(v_avg,2), c.target_cost_per_spin);
    end if;
    if not u.can_override_cost_target then raise exception 'OVERRIDE_NOT_AUTHORISED'; end if;
  end if;

  select coalesce(max(version),0) + 1 into v_ver from public.prize_configs where campaign_id = p_campaign;
  select id into v_prev from public.prize_configs
   where campaign_id = p_campaign and is_active and state_id is not distinct from p_state;
  update public.prize_configs set is_active = false where id = v_prev;

  insert into public.prize_configs(campaign_id, state_id, version, pool_size, total_cost, avg_cost, target_cost,
      exceeds_target, override_by, is_active, notes, created_by)
  values (p_campaign, p_state, v_ver, p_pool_size, v_total, v_avg, c.target_cost_per_spin,
      v_avg > c.target_cost_per_spin, case when v_avg > c.target_cost_per_spin then u.id end, true, p_notes, u.id)
  returning id into v_id;

  insert into public.prize_config_items(config_id, prize_id, quantity, unit_cost)
  select v_id, (e->>'prize_id')::uuid, (e->>'quantity')::int, (e->>'unit_cost')::numeric
    from jsonb_array_elements(p_items) e where (e->>'quantity')::int > 0;

  perform public.write_audit('PRIZE_CONFIG_SAVED', 'prize_configs', v_id::text,
    jsonb_build_object('campaign', c.code, 'state_id', p_state, 'version', v_ver, 'pool_size', p_pool_size,
                       'total_cost', v_total, 'avg_cost', v_avg, 'override', v_avg > c.target_cost_per_spin,
                       'previous_config', v_prev, 'items', p_items));
  return jsonb_build_object('config_id', v_id, 'version', v_ver, 'total_cost', v_total, 'avg_cost', round(v_avg,2),
                            'exceeds_target', v_avg > c.target_cost_per_spin);
end $$;

-- ---------------------------------------------------------------------
-- POOL DASHBOARD — aggregates only, never the sequence
-- ---------------------------------------------------------------------
create or replace function public.pool_status(p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_configs jsonb; v_pools jsonb; v_total jsonb;
begin
  perform public._require_admin();

  select coalesce(jsonb_agg(jsonb_build_object(
      'config_id', pc.id, 'version', pc.version, 'state_id', pc.state_id, 'state_name', st.name,
      'pool_size', pc.pool_size, 'total_cost', pc.total_cost, 'avg_cost', round(pc.avg_cost,2),
      'target', pc.target_cost, 'exceeds_target', pc.exceeds_target, 'created_at', pc.created_at,
      'items', (select jsonb_agg(jsonb_build_object('prize_id', i.prize_id, 'name', p.name, 'short_name', p.short_name,
                     'quantity', i.quantity, 'unit_cost', i.unit_cost) order by i.unit_cost)
                  from public.prize_config_items i join public.prizes p on p.id = i.prize_id where i.config_id = pc.id)
    ) order by pc.state_id nulls first), '[]'::jsonb)
    into v_configs
    from public.prize_configs pc left join public.states st on st.id = pc.state_id
   where pc.campaign_id = p_campaign and pc.is_active;

  select coalesce(jsonb_agg(x order by x->>'owner'), '[]'::jsonb) into v_pools from (
    select jsonb_build_object(
      'pool_id', pp.id, 'pool_no', pp.pool_no, 'scope', pp.scope,
      'owner', coalesce(au.full_name, o.name, tr.name, st.name, 'Campaign'),
      'config_version', pc.version, 'size', pp.size, 'used', pp.used, 'remaining', pp.size - pp.used,
      'remaining_by_prize', (select jsonb_object_agg(p.short_name, n) from (
            select sl.prize_id, count(*) n from public.prize_pool_slots sl
             where sl.pool_id = pp.id and sl.used_at is null group by sl.prize_id) q
            join public.prizes p on p.id = q.prize_id),
      'deferred', (select count(*) from public.prize_pool_slots sl where sl.pool_id = pp.id and sl.used_at is null and sl.deferred_at is not null)
    ) x
    from public.prize_pools pp
    join public.prize_configs pc on pc.id = pp.config_id
    left join public.app_users au on pp.scope = 'promoter' and au.id::text = pp.scope_key
    left join public.outlets o on pp.scope = 'outlet' and o.id::text = pp.scope_key
    left join public.territories tr on pp.scope = 'territory' and tr.id::text = pp.scope_key
    left join public.states st on pp.scope = 'state' and st.id::text = pp.scope_key
   where pp.campaign_id = p_campaign and pp.exhausted_at is null and pp.voided_at is null) t;

  select jsonb_build_object(
      'open_pools', count(*) filter (where exhausted_at is null and voided_at is null),
      'completed_pools', count(*) filter (where exhausted_at is not null),
      'voided_pools', count(*) filter (where voided_at is not null),
      'used', coalesce(sum(used) filter (where exhausted_at is null and voided_at is null),0),
      'capacity', coalesce(sum(size) filter (where exhausted_at is null and voided_at is null),0),
      'total_spins_all_pools', coalesce(sum(used),0))
    into v_total
    from public.prize_pools where campaign_id = p_campaign;

  return jsonb_build_object('configs', v_configs, 'pools', v_pools, 'totals', v_total);
end $$;

-- ---------------------------------------------------------------------
-- OUTLET MASTER BULK UPLOAD (Excel/CSV parsed in browser → JSON rows)
-- row keys: state, territory, tse_code, tse_name, outlet_code, outlet_name, area, city, distributor, status
-- ---------------------------------------------------------------------
create or replace function public.import_outlets(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; i int := 0; v_state uuid; v_terr uuid; v_tse uuid; v_ins int := 0; v_upd int := 0;
        v_err jsonb := '[]'::jsonb; v_exists boolean; v_status public.record_status;
begin
  perform public._require_admin();
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    begin
      if coalesce(r->>'state','') = '' or coalesce(r->>'territory','') = '' or coalesce(r->>'tse_code','') = ''
         or coalesce(r->>'outlet_code','') = '' or coalesce(r->>'outlet_name','') = '' then
        raise exception 'Missing state / territory / tse_code / outlet_code / outlet_name';
      end if;
      v_status := case when lower(coalesce(r->>'status','active')) in ('inactive','n','no','0','closed') then 'inactive' else 'active' end;

      select id into v_state from public.states where lower(name) = lower(trim(r->>'state')) or lower(code) = lower(trim(r->>'state'));
      if v_state is null then
        insert into public.states(code, name) values (upper(left(regexp_replace(trim(r->>'state'),'[^A-Za-z]','','g'),3)) || '-' || substr(gen_random_uuid()::text,1,4), trim(r->>'state'))
        returning id into v_state;
      end if;

      select id into v_terr from public.territories where state_id = v_state and (lower(name) = lower(trim(r->>'territory')) or lower(code) = lower(trim(r->>'territory')));
      if v_terr is null then
        insert into public.territories(state_id, code, name)
        values (v_state, upper(left(regexp_replace(trim(r->>'territory'),'[^A-Za-z]','','g'),4)) || '-' || substr(gen_random_uuid()::text,1,4), trim(r->>'territory'))
        returning id into v_terr;
      end if;

      select id into v_tse from public.tses where lower(code) = lower(trim(r->>'tse_code'));
      if v_tse is null then
        insert into public.tses(territory_id, code, name) values (v_terr, trim(r->>'tse_code'), coalesce(nullif(trim(r->>'tse_name'),''), trim(r->>'tse_code')))
        returning id into v_tse;
      else
        update public.tses set territory_id = v_terr, name = coalesce(nullif(trim(r->>'tse_name'),''), name)
         where id = v_tse and (territory_id <> v_terr or name <> coalesce(nullif(trim(r->>'tse_name'),''), name));
      end if;

      select true into v_exists from public.outlets where outlet_code = trim(r->>'outlet_code');
      insert into public.outlets(tse_id, outlet_code, name, area, city, distributor, status, source)
      values (v_tse, trim(r->>'outlet_code'), trim(r->>'outlet_name'), nullif(trim(r->>'area'),''), nullif(trim(r->>'city'),''),
              nullif(trim(r->>'distributor'),''), v_status, 'upload')
      on conflict (outlet_code) do update
         set tse_id = excluded.tse_id, name = excluded.name, area = excluded.area, city = excluded.city,
             distributor = excluded.distributor, status = excluded.status;
      if coalesce(v_exists,false) then v_upd := v_upd + 1; else v_ins := v_ins + 1; end if;
      v_exists := false;
    exception when others then
      v_err := v_err || jsonb_build_array(jsonb_build_object('row', i, 'error', sqlerrm));
    end;
  end loop;
  perform public.write_audit('OUTLET_MASTER_UPLOAD', 'outlets', null,
    jsonb_build_object('rows', i, 'inserted', v_ins, 'updated', v_upd, 'errors', jsonb_array_length(v_err)));
  return jsonb_build_object('rows', i, 'inserted', v_ins, 'updated', v_upd, 'errors', v_err);
end $$;

-- ---------------------------------------------------------------------
-- REPORTING
-- p_filters: {date_from, date_to, campaign_id, state_id, territory_id, tse_id, outlet_id,
--             promoter_id, product_id, city, distributor}
-- ---------------------------------------------------------------------
create or replace function public._sales_where() returns text
language sql immutable as $f$
  select $$ s.status <> 'cancelled'
    and ($1->>'date_from'   is null or s.biz_date >= ($1->>'date_from')::date)
    and ($1->>'date_to'     is null or s.biz_date <= ($1->>'date_to')::date)
    and ($1->>'campaign_id' is null or s.campaign_id  = ($1->>'campaign_id')::uuid)
    and ($1->>'state_id'    is null or s.state_id     = ($1->>'state_id')::uuid)
    and ($1->>'territory_id' is null or s.territory_id = ($1->>'territory_id')::uuid)
    and ($1->>'tse_id'      is null or s.tse_id       = ($1->>'tse_id')::uuid)
    and ($1->>'outlet_id'   is null or s.outlet_id    = ($1->>'outlet_id')::uuid)
    and ($1->>'promoter_id' is null or s.promoter_id  = ($1->>'promoter_id')::uuid)
    and ($1->>'product_id'  is null or s.product_id   = ($1->>'product_id')::uuid)
    and ($1->>'city'        is null or s.outlet_city  = $1->>'city')
    and ($1->>'distributor' is null or s.distributor  = $1->>'distributor')
    and ($2 or s.promoter_id in (select user_id from public.promoters where supervisor_id = $3)) $$
$f$;

create or replace function public.report_summary(p_group text, p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u public.app_users; v_sel text; v_grp text; v_sql text; v_res jsonb; f jsonb := coalesce(p_filters,'{}'::jsonb);
begin
  u := public._require_staff();
  -- strip empty strings from filters
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into f from jsonb_each(f) where value not in ('""'::jsonb, 'null'::jsonb);

  if p_group = 'prize' then
    v_sql := format($q$
      select coalesce(jsonb_agg(t order by t.unit_cost desc), '[]'::jsonb) from (
        select sp.prize_id as key, max(sp.prize_name) as label, count(*) as quantity,
               round(avg(sp.prize_cost),2) as unit_cost, sum(sp.prize_cost) as total_cost,
               round(100.0 * count(*) / nullif(sum(count(*)) over (), 0), 2) as pct,
               count(*) filter (where sp.redemption_status = 'handed_over') as handed_over,
               count(*) filter (where sp.redemption_status = 'pending') as pending
          from public.spins sp join public.sales s on s.id = sp.sale_id
         where sp.redemption_status <> 'not_redeemed' and %s
         group by sp.prize_id) t $q$, public._sales_where());
    execute v_sql into v_res using f, (u.role = 'admin'), u.id;
    return v_res;
  end if;

  case p_group
    when 'state'       then v_sel := 's.state_id as key, s.state_name as label'; v_grp := 's.state_id, s.state_name';
    when 'territory'   then v_sel := 's.territory_id as key, s.territory_name as label, max(s.state_name) as state'; v_grp := 's.territory_id, s.territory_name';
    when 'tse'         then v_sel := 's.tse_id as key, s.tse_name as label, max(s.tse_code) as tse_code, max(s.territory_name) as territory, max(s.state_name) as state'; v_grp := 's.tse_id, s.tse_name';
    when 'outlet'      then v_sel := 's.outlet_id as key, s.outlet_name as label, max(s.outlet_code) as outlet_code, max(s.outlet_area) as area, max(s.outlet_city) as city, max(s.tse_name) as tse, max(s.territory_name) as territory, max(s.distributor) as distributor'; v_grp := 's.outlet_id, s.outlet_name';
    when 'promoter'    then v_sel := 's.promoter_id as key, s.promoter_name as label, max(s.promoter_code) as promoter_code, max(s.promoter_type::text) as promoter_type, string_agg(distinct s.state_name, '', '') as state, string_agg(distinct s.territory_name, '', '') as territory'; v_grp := 's.promoter_id, s.promoter_name';
    when 'product'     then v_sel := 's.product_id as key, s.product_name as label, max(s.sku_code) as sku_code'; v_grp := 's.product_id, s.product_name';
    when 'date'        then v_sel := 's.biz_date as key, to_char(s.biz_date, ''DD Mon YYYY'') as label'; v_grp := 's.biz_date';
    when 'city'        then v_sel := 'coalesce(s.outlet_city,''—'') as key, coalesce(s.outlet_city,''—'') as label'; v_grp := 's.outlet_city';
    when 'distributor' then v_sel := 'coalesce(s.distributor,''—'') as key, coalesce(s.distributor,''—'') as label'; v_grp := 's.distributor';
    else raise exception 'INVALID_GROUP';
  end case;

  v_sql := format($q$
    select coalesce(jsonb_agg(t order by t.spins desc, t.label), '[]'::jsonb) from (
      select %s,
             count(*) as sales, sum(s.quantity) as units, sum(x.spins) as spins,
             coalesce(sum(x.cost),0) as giveaway_cost,
             round(coalesce(sum(x.cost),0) / nullif(sum(x.spins),0), 2) as avg_cost,
             sum(x.handed) as prizes_given,
             count(distinct s.outlet_id) as active_outlets,
             count(distinct s.promoter_id) as promoters
        from public.sales s
        cross join lateral (
          select count(*) as spins,
                 sum(prize_cost) filter (where redemption_status <> 'not_redeemed') as cost,
                 count(*) filter (where redemption_status = 'handed_over') as handed
            from public.spins where sale_id = s.id) x
       where %s
       group by %s) t $q$, v_sel, public._sales_where(), v_grp);
  execute v_sql into v_res using f, (u.role = 'admin'), u.id;
  return v_res;
end $$;

-- KPI block for supervisor / admin dashboards
create or replace function public.dashboard_kpis(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; f jsonb; v_tot jsonb; v_prizes jsonb; v_stock jsonb; v_low jsonb; v_flags int; v_budget jsonb;
        v_camp public.campaigns; v_used numeric; v_used_today numeric; v_avg numeric; v_pending int; v_active_now int; v_req int;
        v_admin boolean;
begin
  u := public._require_staff();
  v_admin := u.role = 'admin';
  perform public.run_flag_scan();
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into f from jsonb_each(coalesce(p_filters,'{}'::jsonb)) where value not in ('""'::jsonb, 'null'::jsonb);

  execute format($q$
    select jsonb_build_object(
      'sales', count(*), 'units', coalesce(sum(s.quantity),0), 'spins', coalesce(sum(x.spins),0),
      'giveaway_cost', coalesce(sum(x.cost),0),
      'avg_cost', round(coalesce(sum(x.cost),0) / nullif(sum(x.spins),0), 2),
      'prizes_given', coalesce(sum(x.handed),0),
      'active_promoters', count(distinct s.promoter_id), 'active_outlets', count(distinct s.outlet_id))
    from public.sales s
    cross join lateral (select count(*) spins, sum(prize_cost) filter (where redemption_status <> 'not_redeemed') cost,
                               count(*) filter (where redemption_status = 'handed_over') handed
                          from public.spins where sale_id = s.id) x
    where %s $q$, public._sales_where()) into v_tot using f, v_admin, u.id;

  execute format($q$
    select coalesce(jsonb_agg(jsonb_build_object('prize_id', p.id, 'name', p.name, 'short_name', p.short_name, 'tier', p.tier,
                  'count', coalesce(q.n,0), 'cost', coalesce(q.cost,0)) order by p.sort_order), '[]'::jsonb)
      from public.prizes p left join (
        select sp.prize_id, count(*) n, sum(sp.prize_cost) cost from public.spins sp join public.sales s on s.id = sp.sale_id
         where sp.redemption_status <> 'not_redeemed' and %s group by sp.prize_id) q on q.prize_id = p.id
     where p.is_active $q$, public._sales_where()) into v_prizes using f, v_admin, u.id;

  select coalesce(jsonb_agg(jsonb_build_object('prize_id', p.id, 'short_name', p.short_name, 'on_hand', coalesce(q.on_hand,0), 'reserved', coalesce(q.reserved,0)) order by p.sort_order), '[]'::jsonb)
    into v_stock
    from public.prizes p left join (
      select i.prize_id, sum(i.on_hand) on_hand, sum(i.reserved) reserved from public.promoter_inventory i
       where public.can_see_promoter(i.promoter_id) and (f->>'promoter_id' is null or i.promoter_id = (f->>'promoter_id')::uuid)
       group by i.prize_id) q on q.prize_id = p.id
   where p.is_active;

  select coalesce(jsonb_agg(jsonb_build_object('promoter_id', i.promoter_id, 'promoter', au.full_name, 'prize', p.short_name,
                 'on_hand', i.on_hand, 'threshold', p.low_stock_threshold) order by i.on_hand, au.full_name), '[]'::jsonb)
    into v_low
    from public.promoter_inventory i join public.prizes p on p.id = i.prize_id join public.app_users au on au.id = i.promoter_id
   where au.is_active and p.is_active and i.on_hand <= p.low_stock_threshold and public.can_see_promoter(i.promoter_id);

  select count(*) into v_flags from public.activity_flags where status = 'open'
     and (promoter_id is null and v_admin or public.can_see_promoter(promoter_id));
  select count(*) into v_pending from public.spins where redemption_status = 'pending' and public.can_see_promoter(promoter_id);
  select count(*) into v_active_now from public.promoter_sessions where work_date = public.ist_today() and public.can_see_promoter(promoter_id);
  select count(*) into v_req from public.outlet_requests where status = 'pending' and public.can_see_promoter(promoter_id);

  -- budget for the selected campaign (or the most recent active one)
  select * into v_camp from public.campaigns
   where (f->>'campaign_id' is null and status = 'active') or id = (f->>'campaign_id')::uuid
   order by created_at desc limit 1;
  if v_camp.id is not null then
    select coalesce(sum(prize_cost),0), coalesce(sum(prize_cost) filter (where biz_date = public.ist_today()),0), avg(prize_cost)
      into v_used, v_used_today, v_avg
      from public.spins where campaign_id = v_camp.id and redemption_status <> 'not_redeemed';
    v_budget := jsonb_build_object('campaign_id', v_camp.id, 'campaign', v_camp.name,
      'total_budget', v_camp.total_budget, 'used', v_used,
      'remaining', case when v_camp.total_budget is null then null else v_camp.total_budget - v_used end,
      'daily_budget', v_camp.daily_budget, 'used_today', v_used_today,
      'avg_cost', round(coalesce(v_avg, v_camp.target_cost_per_spin), 2),
      'target', v_camp.target_cost_per_spin,
      'est_spins_remaining', case when v_camp.total_budget is null then null
            else floor((v_camp.total_budget - v_used) / nullif(coalesce(v_avg, v_camp.target_cost_per_spin),0)) end,
      'state_budgets', (select jsonb_agg(jsonb_build_object('state', st.name, 'budget', cs.budget,
            'used', (select coalesce(sum(sp.prize_cost),0) from public.spins sp join public.sales sa on sa.id = sp.sale_id
                      where sp.campaign_id = v_camp.id and sa.state_id = cs.state_id and sp.redemption_status <> 'not_redeemed')))
            from public.campaign_states cs join public.states st on st.id = cs.state_id
           where cs.campaign_id = v_camp.id and cs.budget is not null));
  end if;

  return jsonb_build_object('totals', v_tot, 'prizes', v_prizes, 'stock', v_stock, 'low_stock', v_low,
    'open_flags', v_flags, 'pending_handovers', v_pending, 'promoters_on_duty', v_active_now,
    'pending_outlet_requests', v_req, 'budget', v_budget, 'biz_date', public.ist_today());
end $$;

-- >>> supabase/migrations/20260928000500_security.sql
-- =====================================================================
-- RIO SPIN & WIN — 005 ROW LEVEL SECURITY, GRANTS, VIEWS
-- Principle: clients READ through RLS; every WRITE that matters goes
-- through a SECURITY DEFINER function that validates + audits it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Enable RLS everywhere
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Master data: everyone signed-in reads, admin writes (no hard deletes)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['states','territories','tses','outlets','products','prizes','campaigns',
                           'campaign_states','campaign_territory_budgets','campaign_products','campaign_promoters']
  loop
    execute format('create policy %I on public.%I for select to authenticated using (public.my_role() is not null)', t||'_read', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_admin())', t||'_admin_ins', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_admin()) with check (public.is_admin())', t||'_admin_upd', t);
    execute format('revoke delete, truncate on public.%I from authenticated', t);
  end loop;
  -- link tables may be deleted by admin
  foreach t in array array['campaign_states','campaign_territory_budgets','campaign_products','campaign_promoters']
  loop
    execute format('grant delete on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.is_admin())', t||'_admin_del', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------
create policy app_users_read on public.app_users for select to authenticated
  using (id = auth.uid() or public.is_admin()
         or (public.my_role() = 'supervisor' and role = 'promoter' and public.can_see_promoter(id)));
create policy app_users_admin_upd on public.app_users for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke insert, delete, truncate on public.app_users from authenticated;   -- created by edge function only

create policy promoters_read on public.promoters for select to authenticated
  using (public.can_see_promoter(user_id));
create policy promoters_admin_upd on public.promoters for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke insert, delete, truncate on public.promoters from authenticated;

-- ---------------------------------------------------------------------
-- Prize configuration & pools
-- ---------------------------------------------------------------------
create policy prize_configs_read on public.prize_configs for select to authenticated using (public.is_staff());
create policy prize_config_items_read on public.prize_config_items for select to authenticated using (public.is_staff());
create policy prize_pools_read on public.prize_pools for select to authenticated using (public.is_admin());
-- prize_pool_slots: NO policy at all → invisible to every API role, including admin
revoke all on public.prize_pool_slots from authenticated, anon;

-- ---------------------------------------------------------------------
-- Transactional data: own / supervised / all
-- ---------------------------------------------------------------------
create policy sales_read on public.sales for select to authenticated using (public.can_see_promoter(promoter_id));
create policy spins_read on public.spins for select to authenticated using (public.can_see_promoter(promoter_id));
create policy promoter_sessions_read on public.promoter_sessions for select to authenticated using (public.can_see_promoter(promoter_id));
create policy promoter_inventory_read on public.promoter_inventory for select to authenticated using (public.can_see_promoter(promoter_id));
create policy inventory_movements_read on public.inventory_movements for select to authenticated using (public.can_see_promoter(promoter_id));
create policy outlet_requests_read on public.outlet_requests for select to authenticated using (public.can_see_promoter(promoter_id));
create policy activity_flags_read on public.activity_flags for select to authenticated
  using (public.is_admin() or (promoter_id is not null and public.my_role() = 'supervisor' and public.can_see_promoter(promoter_id)));
create policy audit_logs_read on public.audit_logs for select to authenticated using (public.is_admin());
create policy sale_validations_read on public.sale_validations for select to authenticated using (public.is_admin());
create policy consumers_read on public.consumers for select to authenticated using (public.is_admin());

-- No direct writes to any of these — functions only
do $$
declare t text;
begin
  foreach t in array array['prize_configs','prize_config_items','prize_pools','sales','spins','promoter_sessions',
                           'promoter_inventory','inventory_movements','outlet_requests','activity_flags','audit_logs',
                           'sale_validations','consumers']
  loop
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
  end loop;
end $$;

grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;
revoke select on public.prize_pool_slots from authenticated;
grant insert, update on public.states, public.territories, public.tses, public.outlets, public.products, public.prizes,
  public.campaigns, public.campaign_states, public.campaign_territory_budgets, public.campaign_products,
  public.campaign_promoters, public.app_users, public.promoters to authenticated;
revoke insert on public.app_users, public.promoters from authenticated;

-- ---------------------------------------------------------------------
-- Reporting view (RLS of the caller applies)
-- ---------------------------------------------------------------------
create or replace view public.v_transactions with (security_invoker = true) as
select
  s.id                as transaction_id,
  sp.spin_code        as spin_id,
  c.code              as campaign_code,
  s.campaign_id,
  s.biz_date          as date,
  to_char(sp.created_at at time zone 'Asia/Kolkata', 'HH24:MI:SS') as time,
  s.state_name        as state,
  s.territory_name    as territory,
  s.tse_id, s.tse_code, s.tse_name,
  s.outlet_id, s.outlet_code, s.outlet_name, s.outlet_area as area, s.outlet_city as city, s.distributor,
  s.promoter_id, s.promoter_code, s.promoter_name, s.promoter_type,
  s.sku_code, s.product_name as sku, s.quantity,
  sp.prize_id, sp.prize_name, sp.prize_cost, sp.substituted,
  sp.redemption_status, sp.inventory_status,
  sp.handed_over_at, s.status as sale_status,
  coalesce(sp.device_ref, s.device_ref) as device_ref,
  s.state_id, s.territory_id, s.product_id,
  sp.config_version,
  sp.created_at       as spun_at
from public.sales s
join public.campaigns c on c.id = s.campaign_id
left join public.spins sp on sp.sale_id = s.id;

grant select on public.v_transactions to authenticated;

-- ---------------------------------------------------------------------
-- Function privileges: internal helpers are NOT callable from the API
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.my_role(), public.is_admin(), public.is_staff(), public.can_see_promoter(uuid),
  public.ist_today(), public.ist_now(),
  -- promoter
  public.set_work_context(uuid, text),
  public.record_sale(uuid, uuid, uuid, int, text, jsonb, timestamptz),
  public.play_spin(uuid, int, text),
  public.confirm_handover(uuid),
  public.my_pending_spin(),
  public.cancel_open_sale(uuid, text),
  public.get_promoter_home(),
  public.submit_outlet_request(text, text, text, text, uuid, text),
  -- supervisor / admin
  public.adjust_stock(uuid, uuid, public.movement_type, int, text, text),
  public.issue_stock_kit(uuid, jsonb, text),
  public.resolve_spin(uuid, text, text),
  public.review_outlet_request(uuid, boolean, uuid, text, text, text, text, text, text),
  public.review_flag(uuid, public.flag_status, text),
  public.raise_flag(uuid, text, text),
  public.report_summary(text, jsonb),
  public.dashboard_kpis(jsonb),
  public.run_flag_scan(),
  -- admin
  public.save_prize_config(uuid, uuid, int, jsonb, boolean, text),
  public.pool_status(uuid),
  public.import_outlets(jsonb),
  public.verify_audit_chain()
to authenticated;

grant execute on function public.write_audit_as(uuid, text, text, text, jsonb) to service_role;

-- Make future functions private by default too
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- >>> supabase/seed.sql
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
  ('50000000-0000-0000-0000-000000000001', 'SNACK5',   '₹5 Snack',                   '₹5 Snack',  'standard', 5,   'SNACK ATTACK,TREAT YOURSELF',   'YOU WON! 🎉',             'SNACK TIME!',                  15, 1),
  ('50000000-0000-0000-0000-000000000002', 'SNACK10',  '₹10 Snack',                  '₹10 Snack', 'standard', 10,  'CRUNCH TIME,RIO SURPRISE',      'YOU WON! 🎉',             'SNACK TIME!',                  5,  2),
  ('50000000-0000-0000-0000-000000000003', 'RIODARE',  'Rio Dare Card Game',         'Rio Dare',  'mid',      40,  'RIO DARE,WIN BIG',              '🔥 YOU WON RIO DARE! 🔥',  'LET THE GAMES BEGIN',          2,  3),
  ('50000000-0000-0000-0000-000000000004', 'SHADES',   'Rio Sunglasses',             'Rio Shades','high',     100, 'RIO SHADES',                    '😎 YOU WON RIO SHADES!',   'LOOKING COOL!',                1,  4),
  ('50000000-0000-0000-0000-000000000005', 'SPEAKER',  'Rio Mini Bluetooth Speaker', 'Speaker',   'jackpot',  200, 'RIO PARTY JACKPOT',             '🎵 RIO PARTY JACKPOT! 🎵', 'YOU WON A BLUETOOTH SPEAKER!', 0,  5);

-- Campaign
insert into public.campaigns (id, code, name, status, start_date, end_date, target_cost_per_spin,
                              total_budget, daily_budget, pool_scope, draw_strategy, oos_mode, config_change_mode)
values ('60000000-0000-0000-0000-000000000001', 'RSW-2026', 'RIO SPIN & WIN 2026', 'active',
        '2026-09-01', '2026-12-31', 10, 500000, 25000, 'promoter', 'controlled_pool', 'defer', 'next_pool');

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


-- >>> 007/008 cumulative allocation system (apply on new installs)
-- =====================================================================
-- RIO SPIN & WIN — 007 CUMULATIVE ALLOCATION SYSTEM
-- Continuous Controlled Cumulative Random Allocation (replaces fixed 200 pool cap)
-- =====================================================================

-- New campaigns share one campaign-wide cumulative ledger by default. The
-- follow-up migration updates the currently active campaign scope.
alter table public.campaigns alter column pool_scope set default 'campaign';

-- 2. Add percentage to prize_config_items
alter table public.prize_config_items add column if not exists percentage numeric(6,3) not null default 0;

-- Backfill percentage from reference 200 pool
update public.prize_config_items i
   set percentage = case
     when coalesce(c.pool_size, 0) > 0 then round((i.quantity::numeric / c.pool_size::numeric) * 100.0, 3)
     else 0
   end
  from public.prize_configs c
 where c.id = i.config_id and coalesce(i.percentage, 0) = 0;

-- 3. Campaign cumulative allocation ledger
create table if not exists public.campaign_allocations (
  id           uuid primary key default gen_random_uuid(),
  campaign_id  uuid not null references public.campaigns(id) on delete cascade,
  scope        public.pool_scope not null,
  scope_key    text not null,
  total_spins  int not null default 0,
  awarded      jsonb not null default '{}'::jsonb, -- {"<prize_id>": count}
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (campaign_id, scope, scope_key)
);
create index if not exists campaign_allocations_lookup
  on public.campaign_allocations (campaign_id, scope, scope_key);

-- This is private allocator state. Only the SECURITY DEFINER RPCs below need it.
alter table public.campaign_allocations enable row level security;
revoke all on public.campaign_allocations from public, anon, authenticated;

-- 4. Get or initialize cumulative allocation tracking
create or replace function public._get_or_create_allocation(
    p_campaign uuid, p_scope public.pool_scope, p_key text)
returns public.campaign_allocations language plpgsql security definer set search_path = public as $$
declare
  v_alloc public.campaign_allocations;
  v_spins int := 0;
  v_awarded jsonb := '{}'::jsonb;
begin
  select * into v_alloc from public.campaign_allocations
   where campaign_id = p_campaign and scope = p_scope and scope_key = p_key
   for update;

  if v_alloc.id is null then
    -- Initialize from existing completed spins for this scope so historical data continues seamlessly
    select coalesce(sum(cnt), 0), coalesce(jsonb_object_agg(prize_id::text, cnt), '{}'::jsonb)
      into v_spins, v_awarded
      from (
        select sp.prize_id, count(*) as cnt
          from public.spins sp
          join public.sales sa on sa.id = sp.sale_id
         where sp.campaign_id = p_campaign
           and (
             (p_scope = 'promoter'  and sp.promoter_id::text = p_key) or
             (p_scope = 'outlet'    and sa.outlet_id::text = p_key) or
             (p_scope = 'territory' and sa.territory_id::text = p_key) or
             (p_scope = 'state'     and sa.state_id::text = p_key) or
             (p_scope = 'campaign'  and sp.campaign_id::text = p_key)
           )
           and sp.redemption_status <> 'not_redeemed'
         group by sp.prize_id
      ) q;

    insert into public.campaign_allocations (campaign_id, scope, scope_key, total_spins, awarded)
    values (p_campaign, p_scope, p_key, coalesce(v_spins, 0), coalesce(v_awarded, '{}'::jsonb))
    on conflict (campaign_id, scope, scope_key) do update
       set updated_at = now()
    returning * into v_alloc;
  end if;

  return v_alloc;
end $$;

-- 5. Draw algorithm: Controlled Cumulative Random Allocation
create or replace function public._draw_cumulative_prize(
    p_campaign public.campaigns,
    p_config public.prize_configs,
    p_promoter uuid,
    p_key text
)
returns table (
    prize_id uuid,
    unit_cost numeric,
    total_spins int
) language plpgsql security definer set search_path = public, extensions as $$
declare
  v_alloc public.campaign_allocations;
  v_n int;
  v_item record;
  v_eligible_count int;
  v_total_weight numeric := 0;
  v_r numeric;
  v_acc numeric := 0;
  v_won_prize uuid;
  v_won_cost numeric;
  v_target numeric;
  v_actual int;
  v_deficit numeric;
  v_stock int;
  v_weight numeric;
  v_best_deficit_prize uuid;
  v_best_deficit numeric := -999999;
  v_best_cost numeric;
  v_excluded uuid[] := '{}'::uuid[];
  v_attempt int := 0;
begin
  -- Serialise draws within this allocation scope atomically
  perform pg_advisory_xact_lock(hashtext('rio_alloc:' || p_campaign.id::text || ':' || p_campaign.pool_scope::text || ':' || p_key));

  -- Strict mode pauses allocation if any configured prize is unavailable.
  if p_campaign.track_inventory and p_campaign.oos_mode = 'block' and exists (
    select 1 from public.prize_config_items i
     where i.config_id = p_config.id
       and coalesce(nullif(i.percentage, 0), i.quantity::numeric / p_config.pool_size * 100.0) > 0
       and public._available(p_promoter, i.prize_id) <= 0
  ) then
    raise exception 'OUT_OF_STOCK' using hint = 'Prize stock is temporarily unavailable. Please contact the supervisor.';
  end if;

  v_alloc := public._get_or_create_allocation(p_campaign.id, p_campaign.pool_scope, p_key);
  v_n := v_alloc.total_spins + 1;

  create temporary table if not exists _spin_candidates (
    p_id uuid,
    p_cost numeric,
    p_pct numeric,
    p_target numeric,
    p_actual int,
    p_deficit numeric,
    p_weight numeric,
    p_constrained boolean
  ) on commit drop;
  loop
    truncate table _spin_candidates;
    v_eligible_count := 0;
    v_total_weight := 0;
    v_acc := 0;
    v_best_deficit := -999999;
    v_best_deficit_prize := null;
    v_best_cost := null;
    v_won_prize := null;

    for v_item in
      select i.prize_id, i.unit_cost,
             case when coalesce(i.percentage, 0) > 0 then i.percentage
                  when coalesce(p_config.pool_size, 0) > 0 then (i.quantity::numeric / p_config.pool_size::numeric) * 100.0
                  else 0 end as pct
        from public.prize_config_items i
       where i.config_id = p_config.id and not (i.prize_id = any(v_excluded))
       order by i.unit_cost desc
    loop
      if v_item.pct > 0 then
        v_stock := case when p_campaign.track_inventory then public._available(p_promoter, v_item.prize_id) else 99999 end;
        v_actual := coalesce((v_alloc.awarded->>v_item.prize_id::text)::int, 0);
        v_target := (v_n::numeric * v_item.pct) / 100.0;
        v_deficit := v_target - v_actual::numeric;
        if v_stock > 0 then
          v_eligible_count := v_eligible_count + 1;
          if v_deficit > v_best_deficit then
            v_best_deficit := v_deficit;
            v_best_deficit_prize := v_item.prize_id;
            v_best_cost := v_item.unit_cost;
          end if;
          insert into _spin_candidates values (v_item.prize_id, v_item.unit_cost, v_item.pct, v_target, v_actual, v_deficit, 0, false);
        end if;
      end if;
    end loop;

    if v_eligible_count = 0 then
      raise exception 'OUT_OF_STOCK' using hint = 'No configured prize is available at this promoter.';
    end if;
    -- Restrict randomness to categories within 1.5 prizes of the largest
    -- eligible deficit. This bounds cumulative rounding error while keeping
    -- ties and near-ties random instead of exposing a fixed sequence.
    update _spin_candidates
       set p_constrained = p_deficit < v_best_deficit - 1.5,
           p_weight = (p_pct / 100.0) * exp(greatest(-4.0, least(0.0, (p_deficit - v_best_deficit) / 0.75)));
    select coalesce(sum(p_weight), 0) into v_total_weight from _spin_candidates where not p_constrained;
    if v_total_weight <= 0 then
      update _spin_candidates set p_constrained = false;
      select sum(p_weight) into v_total_weight from _spin_candidates;
    end if;
    v_r := ((('x' || encode(extensions.gen_random_bytes(6), 'hex'))::bit(48)::bigint)::numeric / 281474976710656) * v_total_weight;
    for v_item in select p_id, p_cost, p_weight from _spin_candidates where not p_constrained order by p_id loop
      v_acc := v_acc + v_item.p_weight;
      if v_r < v_acc then
        v_won_prize := v_item.p_id;
        v_won_cost := v_item.p_cost;
        exit;
      end if;
    end loop;
    if v_won_prize is null then
      select p_id, p_cost into v_won_prize, v_won_cost from _spin_candidates where not p_constrained order by p_weight desc limit 1;
    end if;

    -- Reserve before recording the award. The UPDATE is atomic across promoters
    -- and outlets sharing a physical stock row; retry another eligible prize if
    -- another request took the last unit while this draw was being calculated.
    if p_campaign.track_inventory then
      update public.promoter_inventory set reserved = reserved + 1, updated_at = now()
       where promoter_id = p_promoter and prize_id = v_won_prize and on_hand - reserved > 0;
      if not found then
        v_excluded := array_append(v_excluded, v_won_prize);
        v_attempt := v_attempt + 1;
        if v_attempt < 100 then continue; end if;
        raise exception 'OUT_OF_STOCK' using hint = 'No configured prize could be reserved.';
      end if;
    end if;
    exit;
  end loop;

  -- Commit allocation progress atomically
  update public.campaign_allocations
     set total_spins = v_n,
         awarded = jsonb_set(
           awarded,
           array[v_won_prize::text],
           to_jsonb(coalesce((awarded->>v_won_prize::text)::int, 0) + 1)
         ),
         updated_at = now()
   where id = v_alloc.id;

  prize_id := v_won_prize;
  unit_cost := v_won_cost;
  total_spins := v_n;
  return next;
end $$;

-- 6. Updated play_spin supporting continuous cumulative allocation
create or replace function public.play_spin(p_sale_id uuid, p_spin_no int default 1, p_device_ref text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u public.app_users; s public.sales; c public.campaigns; cfg public.prize_configs; pool public.prize_pools;
  v_existing uuid; v_key text; v_spin_id uuid := gen_random_uuid();
  v_pos int := null; v_prize uuid; v_cost numeric; v_orig uuid := null; v_sub boolean := false;
  pz public.prizes; v_inv_status text; v_alloc_res record;
begin
  u := public._require_promoter();

  select * into s from public.sales where id = p_sale_id for update;
  if s.id is null or s.promoter_id <> u.id then raise exception 'SALE_NOT_FOUND'; end if;

  -- Idempotency: exact same (sale, spin_no) returns existing draw
  select id into v_existing from public.spins where sale_id = s.id and spin_no = p_spin_no;
  if v_existing is not null then return public._spin_json(v_existing) || jsonb_build_object('replayed', true); end if;

  if s.status = 'cancelled' then raise exception 'SALE_CANCELLED'; end if;
  if p_spin_no < 1 or p_spin_no <> s.spins_used + 1 or p_spin_no > s.spins_allowed then
    raise exception 'NO_SPINS_LEFT' using hint = 'This sale has already used its spin.';
  end if;

  select * into c from public.campaigns where id = s.campaign_id;
  if c.status <> 'active' then raise exception 'CAMPAIGN_NOT_ACTIVE'; end if;
  cfg := public._active_config(c.id, s.state_id);
  if cfg.id is null then raise exception 'NO_PRIZE_CONFIG'; end if;
  v_key := public._pool_key(c.pool_scope, s);

  -- Perform Controlled Cumulative Random Allocation
  select * into v_alloc_res from public._draw_cumulative_prize(c, cfg, u.id, v_key);
  v_prize := v_alloc_res.prize_id;
  v_cost  := v_alloc_res.unit_cost;

  select * into pz from public.prizes where id = v_prize;
  if pz.id is null then raise exception 'OUT_OF_STOCK'; end if;

  -- _draw_cumulative_prize reserves the unit before committing allocation state.
  if c.track_inventory then
    v_inv_status := 'reserved';
  else
    v_inv_status := 'not_tracked';
  end if;

  insert into public.spins(id, spin_code, sale_id, spin_no, campaign_id, promoter_id, biz_date,
      strategy, pool_id, slot_position, config_id, config_version,
      prize_id, prize_code, prize_name, prize_tier, prize_cost, original_prize_id, substituted,
      inventory_status, device_ref)
  values (v_spin_id,
      'SPN' || to_char(public.ist_now(),'YYMMDD') || '-' || lpad(nextval('public.spin_code_seq')::text, 6, '0'),
      s.id, p_spin_no, c.id, u.id, public.ist_today(),
      c.draw_strategy, null, null, cfg.id, cfg.version,
      pz.id, pz.code, pz.name, pz.tier, v_cost, v_orig, v_sub,
      v_inv_status, coalesce(p_device_ref, s.device_ref));

  update public.sales set spins_used = spins_used + 1, status = 'spun' where id = s.id;

  perform public.write_audit('SPIN', 'spins', v_spin_id::text,
    jsonb_build_object('sale_id', s.id, 'prize', pz.code, 'cost', v_cost, 'strategy', c.draw_strategy,
                       'allocation_algorithm', 'cumulative_quota_randomized_near_ties',
                       'config_version', cfg.version, 'outlet_code', s.outlet_code));

  perform public._check_after_spin(v_spin_id);
  return public._spin_json(v_spin_id) || jsonb_build_object('replayed', false);
end $$;

-- Functions added after the base RLS migration must explicitly retain its
-- private-helper rule. Only the public RPC entry points are callable by clients.
revoke execute on function public._get_or_create_allocation(uuid, public.pool_scope, text) from public, anon, authenticated;
revoke execute on function public._draw_cumulative_prize(public.campaigns, public.prize_configs, uuid, text) from public, anon, authenticated;

-- 7. Updated save_prize_config supporting percentages & dynamic cost
create or replace function public.save_prize_config(p_campaign uuid, p_state uuid, p_pool_size int,
    p_items jsonb, p_override boolean default false, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u public.app_users; c public.campaigns;
  v_ref_size int; v_tot_pct numeric := 0; v_avg numeric := 0;
  v_ver int; v_id uuid; v_prev uuid; v_total numeric := 0;
  e jsonb; v_pct numeric; v_cost numeric; v_qty int;
begin
  u := public._require_admin();
  select * into c from public.campaigns where id = p_campaign;
  if c.id is null then raise exception 'CAMPAIGN_NOT_FOUND'; end if;

  v_ref_size := coalesce(p_pool_size, 200);
  if v_ref_size < 1 then v_ref_size := 200; end if;

  for e in select * from jsonb_array_elements(p_items) loop
    v_cost := (e->>'unit_cost')::numeric;
    v_pct := coalesce((e->>'percentage')::numeric,
                      case when v_ref_size > 0 then ((e->>'quantity')::numeric / v_ref_size::numeric) * 100.0 else 0 end);
    if v_pct < 0 or v_cost < 0 then raise exception 'INVALID_ITEMS'; end if;
    v_tot_pct := v_tot_pct + v_pct;
    v_avg := v_avg + (v_pct / 100.0) * v_cost;
  end loop;

  if abs(v_tot_pct - 100.0) > 0.05 then
    raise exception 'PERCENTAGE_MISMATCH' using hint = format('Prize percentages add up to %s%%; they must equal 100%%', round(v_tot_pct, 2));
  end if;

  v_avg := round(v_avg, 4);
  v_total := round(v_avg * v_ref_size, 2);

  if v_avg > c.target_cost_per_spin then
    if not coalesce(p_override, false) then
      raise exception 'COST_ABOVE_TARGET' using detail = v_avg::text,
        hint = format('Average cost per spin ₹%s exceeds the ₹%s campaign target.', round(v_avg,2), c.target_cost_per_spin);
    end if;
    if not u.can_override_cost_target then raise exception 'OVERRIDE_NOT_AUTHORISED'; end if;
  end if;

  select coalesce(max(version), 0) + 1 into v_ver from public.prize_configs where campaign_id = p_campaign;
  select id into v_prev from public.prize_configs
   where campaign_id = p_campaign and is_active and state_id is not distinct from p_state;
  update public.prize_configs set is_active = false where id = v_prev;

  insert into public.prize_configs(campaign_id, state_id, version, pool_size, total_cost, avg_cost, target_cost,
      exceeds_target, override_by, is_active, notes, created_by)
  values (p_campaign, p_state, v_ver, v_ref_size, v_total, v_avg, c.target_cost_per_spin,
      v_avg > c.target_cost_per_spin, case when v_avg > c.target_cost_per_spin then u.id end, true, p_notes, u.id)
  returning id into v_id;

  insert into public.prize_config_items(config_id, prize_id, quantity, unit_cost, percentage)
  select v_id,
         (el->>'prize_id')::uuid,
         coalesce((el->>'quantity')::int, round((coalesce((el->>'percentage')::numeric, 0) / 100.0) * v_ref_size)::int),
         (el->>'unit_cost')::numeric,
         coalesce((el->>'percentage')::numeric, round(((el->>'quantity')::numeric / v_ref_size::numeric) * 100.0, 3))
    from jsonb_array_elements(p_items) el
   where coalesce((el->>'percentage')::numeric, (el->>'quantity')::numeric) > 0;

  perform public.write_audit('PRIZE_CONFIG_SAVED', 'prize_configs', v_id::text,
    jsonb_build_object('campaign', c.code, 'state_id', p_state, 'version', v_ver, 'ref_pool_size', v_ref_size,
                       'expected_cost', v_avg, 'override', v_avg > c.target_cost_per_spin, 'items', p_items));

  return jsonb_build_object('config_id', v_id, 'version', v_ver, 'total_cost', v_total, 'avg_cost', round(v_avg,2),
                            'exceeds_target', v_avg > c.target_cost_per_spin);
end $$;

-- 8. Updated pool_status: returns CAMPAIGN SPIN DISTRIBUTION (no 200 cap)
create or replace function public.pool_status(p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_configs jsonb;
  v_distribution jsonb;
  v_total_spins int := 0;
  v_giveaway_cost numeric := 0;
  v_avg_cost numeric := 0;
  v_cfg_id uuid;
  v_target_cost numeric := 10.0;
begin
  perform public._require_admin();

  select coalesce(jsonb_agg(jsonb_build_object(
      'config_id', pc.id, 'version', pc.version, 'state_id', pc.state_id, 'state_name', st.name,
      'pool_size', pc.pool_size, 'total_cost', pc.total_cost, 'avg_cost', round(pc.avg_cost,2),
      'target', pc.target_cost, 'exceeds_target', pc.exceeds_target, 'created_at', pc.created_at,
      'items', (select jsonb_agg(jsonb_build_object(
                     'prize_id', i.prize_id, 'name', p.name, 'short_name', p.short_name, 'tier', p.tier,
                     'percentage', coalesce(i.percentage, round((i.quantity::numeric / pc.pool_size::numeric)*100.0, 2)),
                     'quantity', i.quantity, 'unit_cost', i.unit_cost) order by i.unit_cost)
                  from public.prize_config_items i join public.prizes p on p.id = i.prize_id where i.config_id = pc.id)
    ) order by pc.state_id nulls first), '[]'::jsonb)
    into v_configs
    from public.prize_configs pc left join public.states st on st.id = pc.state_id
   where pc.campaign_id = p_campaign and pc.is_active;

  -- Cumulative campaign metrics
  select count(*) filter (where redemption_status <> 'not_redeemed'),
         coalesce(sum(prize_cost) filter (where redemption_status <> 'not_redeemed'), 0)
    into v_total_spins, v_giveaway_cost
    from public.spins
   where campaign_id = p_campaign;

  if v_total_spins > 0 then
    v_avg_cost := round(v_giveaway_cost / v_total_spins, 2);
  else
    v_avg_cost := 0;
  end if;

  select id, target_cost into v_cfg_id, v_target_cost
    from public.prize_configs
   where campaign_id = p_campaign and is_active and state_id is null
   limit 1;

  -- Build CAMPAIGN SPIN DISTRIBUTION items
  with actual_awards as (
    select prize_id, count(*) as actual_count, sum(prize_cost) as total_prize_cost
      from public.spins
     where campaign_id = p_campaign and redemption_status <> 'not_redeemed'
     group by prize_id
  ),
  cfg_items as (
    select i.prize_id, p.name, p.short_name, p.tier, i.unit_cost,
           coalesce(nullif(i.percentage, 0), case when pc.pool_size > 0 then (i.quantity::numeric / pc.pool_size::numeric) * 100.0 else 0 end) as target_pct
      from public.prize_configs pc
      join public.prize_config_items i on i.config_id = pc.id
      join public.prizes p on p.id = i.prize_id
     where pc.id = v_cfg_id
  ), target_awards as (
    select i.prize_id,
           sum(coalesce(nullif(i.percentage, 0), case when pc.pool_size > 0 then i.quantity::numeric / pc.pool_size * 100.0 else 0 end) / 100.0) as target_count
      from public.spins sp
      join public.prize_config_items i on i.config_id = sp.config_id
      join public.prize_configs pc on pc.id = sp.config_id
     where sp.campaign_id = p_campaign and sp.redemption_status <> 'not_redeemed'
     group by i.prize_id
  ), prize_catalog as (
    select p.id as prize_id, p.name, p.short_name, p.tier,
           coalesce(ci.unit_cost, aa.unit_cost, p.default_cost) as unit_cost,
           coalesce(ci.target_pct, 0) as current_target_pct,
           coalesce(ta.target_count, 0) as target_count,
           coalesce(aa.actual_count, 0) as actual_count,
           coalesce(aa.total_prize_cost, 0) as total_prize_cost
      from public.prizes p
      left join cfg_items ci on ci.prize_id = p.id
      left join actual_awards aa on aa.prize_id = p.id
      left join target_awards ta on ta.prize_id = p.id
     where p.is_active and (ci.prize_id is not null or aa.prize_id is not null or ta.prize_id is not null)
  )
  select jsonb_build_object(
      'total_spins', v_total_spins,
      'giveaway_cost', v_giveaway_cost,
      'avg_giveaway_cost', v_avg_cost,
      'target_cost', v_target_cost,
      'items', coalesce(jsonb_agg(jsonb_build_object(
        'prize_id', pc.prize_id,
        'name', pc.name,
        'short_name', pc.short_name,
        'tier', pc.tier,
        'unit_cost', pc.unit_cost,
        'target_pct', case when v_total_spins > 0 then round(pc.target_count * 100.0 / v_total_spins, 2) else round(pc.current_target_pct, 2) end,
        'target_count', round(pc.target_count, 1),
        'actual_count', pc.actual_count,
        'actual_pct', case when v_total_spins > 0 then round((pc.actual_count::numeric / v_total_spins::numeric) * 100.0, 2) else 0 end,
        'variance_pct', case when v_total_spins > 0 then round(((pc.actual_count::numeric / v_total_spins::numeric) * 100.0) - (pc.target_count * 100.0 / v_total_spins), 2) else 0 end,
        'total_cost', pc.total_prize_cost
      ) order by pc.unit_cost), '[]'::jsonb)
    )
    into v_distribution
    from prize_catalog pc;

  return jsonb_build_object(
    'configs', v_configs,
    'distribution', v_distribution,
    'pools', '[]'::jsonb,
    'totals', jsonb_build_object(
      'total_spins_all_pools', v_total_spins,
      'used', v_total_spins,
      'giveaway_cost', v_giveaway_cost,
      'avg_cost', v_avg_cost
    )
  );
end $$;

-- Filterable prize report with actual and target shares based on each spin's
-- immutable configuration snapshot.
create or replace function public.prize_distribution_report(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u public.app_users; f jsonb := coalesce(p_filters, '{}'::jsonb); v_res jsonb;
begin
  u := public._require_staff();
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into f
    from jsonb_each(f) where value not in ('""'::jsonb, 'null'::jsonb);

  execute format($q$
    with filtered as (
      select sp.* from public.spins sp join public.sales s on s.id = sp.sale_id
       where sp.redemption_status <> 'not_redeemed' and %s
    ), totals as (
      select count(*)::numeric as n from filtered
    ), actual as (
      select prize_id, count(*) as n, sum(prize_cost) as cost,
             count(*) filter (where redemption_status = 'handed_over') as handed,
             count(*) filter (where redemption_status = 'pending') as pending,
             max(prize_name) as label, avg(prize_cost) as unit_cost
        from filtered group by prize_id
    ), targets as (
      select i.prize_id,
             sum(coalesce(nullif(i.percentage, 0),
                 case when pc.pool_size > 0 then i.quantity::numeric / pc.pool_size * 100.0 else 0 end)) as target_points
        from filtered f
        join public.prize_config_items i on i.config_id = f.config_id
        join public.prize_configs pc on pc.id = f.config_id
       group by i.prize_id
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', p.id, 'label', p.name,
      'quantity', coalesce(a.n, 0),
      'unit_cost', round(coalesce(a.unit_cost, p.default_cost), 2),
      'total_cost', coalesce(a.cost, 0),
      'pct', case when t.n > 0 then round(coalesce(a.n, 0)::numeric * 100.0 / t.n, 2) else 0 end,
      'target_pct', case when t.n > 0 then round(coalesce(g.target_points, 0) / t.n, 2) else 0 end,
      'variance_pct', case when t.n > 0 then round(coalesce(a.n, 0)::numeric * 100.0 / t.n - coalesce(g.target_points, 0) / t.n, 2) else 0 end,
      'handed_over', coalesce(a.handed, 0), 'pending', coalesce(a.pending, 0),
      'total_spins', t.n,
      'giveaway_cost', (select coalesce(sum(cost), 0) from actual),
      'avg_giveaway_cost', case when t.n > 0 then round((select coalesce(sum(cost), 0) from actual) / t.n, 2) else 0 end
    ) order by p.sort_order), '[]'::jsonb)
      from public.prizes p cross join totals t
      left join actual a on a.prize_id = p.id
      left join targets g on g.prize_id = p.id
     where p.is_active
  $q$, public._sales_where()) into v_res using f, (u.role = 'admin'), u.id;
  return v_res;
end $$;

revoke execute on function public.prize_distribution_report(jsonb) from public, anon, authenticated;
grant execute on function public.prize_distribution_report(jsonb) to authenticated;

-- 9. Updated get_promoter_home: REMOVES prize_cost and avg_cost from Promoter dashboard
create or replace function public.get_promoter_home()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u public.app_users; pr public.promoters; v_today jsonb; v_stock jsonb; v_session jsonb;
begin
  u := public._require_promoter();
  select * into pr from public.promoters where user_id = u.id;

  -- Operational metrics only (no financial prize costs / averages)
  select jsonb_build_object(
      'sales', (select count(*) from public.sales where promoter_id = u.id and biz_date = public.ist_today() and status <> 'cancelled'),
      'units', (select coalesce(sum(quantity),0) from public.sales where promoter_id = u.id and biz_date = public.ist_today() and status <> 'cancelled'),
      'spins', count(*),
      'prizes_given', count(*) filter (where redemption_status = 'handed_over'))
    into v_today
    from public.spins where promoter_id = u.id and biz_date = public.ist_today();

  select coalesce(jsonb_agg(jsonb_build_object(
      'prize_id', p.id, 'name', p.name, 'short_name', p.short_name, 'tier', p.tier,
      'on_hand', coalesce(i.on_hand,0), 'reserved', coalesce(i.reserved,0),
      'threshold', p.low_stock_threshold,
      'low', coalesce(i.on_hand,0) <= p.low_stock_threshold) order by p.sort_order), '[]'::jsonb)
    into v_stock
    from public.prizes p
    left join public.promoter_inventory i on i.prize_id = p.id and i.promoter_id = u.id
   where p.is_active;

  select to_jsonb(x) into v_session from (
    select ps.work_date, ps.campaign_id, c.name campaign_name, ps.state_id, ps.territory_id, ps.tse_id, ps.outlet_id
      from public.promoter_sessions ps left join public.campaigns c on c.id = ps.campaign_id
     where ps.promoter_id = u.id and ps.work_date = public.ist_today()) x;

  return jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'name', u.full_name, 'login_id', u.login_id,
                               'promoter_code', pr.promoter_code, 'promoter_type', pr.promoter_type),
    'today', v_today, 'stock', v_stock, 'session', v_session,
    'pending_spin', public.my_pending_spin(),
    'biz_date', public.ist_today());
end $$;

-- Make the existing active RIO campaign use one campaign-wide cumulative
-- ledger. Historic spins remain unchanged; the allocator seeds its ledger from
-- their persisted prize results the first time the campaign is spun again.
update public.campaigns
   set pool_scope = 'campaign'
 where status = 'active';

-- Migration 20260930000100_regional_customers_launch_phase.sql
-- Regional SKUs, customer capture and manually controlled launch allocation.
alter table public.spins add column if not exists allocation_phase text not null default 'standard' check (allocation_phase in ('standard','snack_launch'));
alter table public.products add column if not exists state_id uuid references public.states(id);
alter table public.campaigns add column if not exists snack_launch_active boolean not null default false;

insert into public.products(sku_code,name,pack,size_ml,state_id,is_active,sort_order)
select v.sku,v.name,'Can',v.ml,st.id,true,v.ord from (values
 ('RIO-GT-330C','Rio Gold Tropical 330 ml Can',330,'UP',1),('RIO-GT-500C','Rio Gold Tropical 500 ml Can',500,'UP',2),
 ('RIO-G-330C','Rio Gold 330 ml Can',330,'MH',3),('RIO-G-500C','Rio Gold 500 ml Can',500,'MH',4),('RIO-G-650C','Rio Gold 650 ml Can',650,'MH',5),
 ('RIO-R-330C','Rio Red 330 ml Can',330,'MH',6),('RIO-R-500C','Rio Red 500 ml Can',500,'MH',7),('RIO-R-650C','Rio Red 650 ml Can',650,'MH',8),('RIO-S-330C','Rio Strong 330 ml Can',330,'MH',9)
) v(sku,name,ml,state_code,ord) join public.states st on st.code=v.state_code
on conflict(sku_code) do update set name=excluded.name,pack=excluded.pack,size_ml=excluded.size_ml,state_id=excluded.state_id,is_active=true,sort_order=excluded.sort_order,updated_at=now();
update public.products set is_active=false,updated_at=now() where sku_code in ('RIO-SR-500C','RIO-SG-500C','RIO-GT-750B');
insert into public.campaign_products(campaign_id,product_id,sort_order)
select distinct c.id,p.id,p.sort_order from public.campaigns c join public.campaign_states cs on cs.campaign_id=c.id join public.products p on p.state_id=cs.state_id and p.is_active
on conflict(campaign_id,product_id) do update set sort_order=excluded.sort_order;

create or replace function public._validate_sale_product_region() returns trigger language plpgsql set search_path=public as $$
declare v_state uuid; begin select state_id into v_state from public.products where id=new.product_id and is_active;
if not found then raise exception 'PRODUCT_NOT_ALLOWED'; end if; if v_state is not null and v_state<>new.state_id then raise exception 'PRODUCT_NOT_ALLOWED' using hint='This product is not available in the selected region.'; end if; return new; end $$;
drop trigger if exists sales_product_region_guard on public.sales;
create trigger sales_product_region_guard before insert or update of product_id,state_id on public.sales for each row execute function public._validate_sale_product_region();


create or replace function public._prepare_campaign_launch_phase() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if not old.snack_launch_active and new.snack_launch_active then
    if new.pool_scope<>'campaign' then raise exception 'SNACK_LAUNCH_REQUIRES_CAMPAIGN_SCOPE'; end if;
    perform public._get_or_create_allocation(new.id,new.pool_scope,new.id::text);
  end if;
  return new;
end $$;
drop trigger if exists campaigns_prepare_launch_phase on public.campaigns;
create trigger campaigns_prepare_launch_phase before update of snack_launch_active on public.campaigns
for each row execute function public._prepare_campaign_launch_phase();

-- During launch, readiness checks consider only the two permitted snacks.
create or replace function public._stock_problem(c public.campaigns,p_config public.prize_configs,p_promoter uuid,p_key text)
returns text language plpgsql stable security definer set search_path=public as $$
declare v_pool uuid; v_missing text; v_any_ok boolean;
begin
  if not c.track_inventory then return null; end if;
  if c.snack_launch_active then
    select string_agg(short_name,', ' order by sort_order) into v_missing from public.prizes
     where code in ('SNACK5','SNACK10') and public._available(p_promoter,id)<=0;
    return v_missing;
  end if;
  if c.draw_strategy='controlled_pool' then
    select id into v_pool from public.prize_pools where campaign_id=c.id and scope=c.pool_scope and scope_key=p_key
      and exhausted_at is null and voided_at is null and (config_id=p_config.id or c.config_change_mode='next_pool');
  end if;
  with remaining as (
    select distinct s.prize_id from public.prize_pool_slots s where v_pool is not null and s.pool_id=v_pool and s.used_at is null
    union
    select i.prize_id from public.prize_config_items i where v_pool is null and i.config_id=p_config.id and i.quantity>0
  )
  select string_agg(p.short_name,', ' order by p.sort_order) filter(where public._available(p_promoter,r.prize_id)<=0),
         bool_or(public._available(p_promoter,r.prize_id)>0)
    into v_missing,v_any_ok from remaining r join public.prizes p on p.id=r.prize_id
   where not c.snack_launch_active or p.code in ('SNACK5','SNACK10');
  if c.oos_mode='block' then return v_missing;
  elsif not coalesce(v_any_ok,false) then return coalesce(v_missing,'all prizes'); end if;
  return null;
end $$;

create or replace function public.capture_sale_customer(p_sale_id uuid,p_name text,p_phone text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare u public.app_users; s public.sales; v_consumer uuid; v_name text:=nullif(btrim(p_name),''); v_phone text:=nullif(btrim(p_phone),'');
begin u:=public._require_promoter(); if v_name is null then raise exception 'CUSTOMER_NAME_REQUIRED'; end if; select * into s from public.sales where id=p_sale_id for update;
if s.id is null or s.promoter_id<>u.id then raise exception 'SALE_NOT_FOUND'; end if; if s.status<>'open' or exists(select 1 from public.spins where sale_id=s.id) then raise exception 'SALE_ALREADY_SPUN'; end if;
if s.consumer_id is null then insert into public.consumers(name,mobile,consent) values(v_name,v_phone,false) returning id into v_consumer; update public.sales set consumer_id=v_consumer where id=s.id;
else update public.consumers set name=v_name,mobile=v_phone where id=s.consumer_id; v_consumer:=s.consumer_id; end if;
perform public.write_audit('CUSTOMER_CAPTURED','sales',s.id::text,jsonb_build_object('phone_provided',v_phone is not null)); return jsonb_build_object('ok',true); end $$;
revoke all on function public.capture_sale_customer(uuid,text,text) from public,anon,authenticated; grant execute on function public.capture_sale_customer(uuid,text,text) to authenticated;

create or replace function public._draw_cumulative_prize(
    p_campaign public.campaigns,
    p_config public.prize_configs,
    p_promoter uuid,
    p_key text
)
returns table (
    prize_id uuid,
    unit_cost numeric,
    total_spins int
) language plpgsql security definer set search_path = public, extensions as $$
declare
  v_alloc public.campaign_allocations;
  v_n int;
  v_item record;
  v_eligible_count int;
  v_total_weight numeric := 0;
  v_r numeric;
  v_acc numeric := 0;
  v_won_prize uuid;
  v_won_cost numeric;
  v_target numeric;
  v_actual int;
  v_deficit numeric;
  v_stock int;
  v_weight numeric;
  v_best_deficit_prize uuid;
  v_best_deficit numeric := -999999;
  v_best_cost numeric;
  v_excluded uuid[] := '{}'::uuid[];
  v_attempt int := 0;
begin
  -- Serialise draws within this allocation scope atomically
  perform pg_advisory_xact_lock(hashtext('rio_alloc:' || p_campaign.id::text || ':' || p_campaign.pool_scope::text || ':' || p_key));

  -- Both snacks must be stocked to honor the strict 85/15 launch ratio.
  if p_campaign.snack_launch_active and p_campaign.track_inventory and exists (select 1 from public.prizes p where p.code in ('SNACK5','SNACK10') and public._available(p_promoter,p.id)<=0) then
    raise exception 'OUT_OF_STOCK' using hint='Both snack prizes must be in stock during the temporary 85/15 launch phase.';
  end if;

  -- Strict mode pauses allocation if any configured prize is unavailable.
  if p_campaign.track_inventory and p_campaign.oos_mode = 'block' and exists (
    select 1 from public.prize_config_items i join public.prizes p on p.id=i.prize_id
     where i.config_id = p_config.id and (not p_campaign.snack_launch_active or p.code in ('SNACK5','SNACK10'))
       and coalesce(nullif(i.percentage, 0), i.quantity::numeric / p_config.pool_size * 100.0) > 0
       and public._available(p_promoter, i.prize_id) <= 0
  ) then
    raise exception 'OUT_OF_STOCK' using hint = 'Prize stock is temporarily unavailable. Please contact the supervisor.';
  end if;

  v_alloc := public._get_or_create_allocation(p_campaign.id, p_campaign.pool_scope, p_key);
  v_n := v_alloc.total_spins + 1;

  create temporary table if not exists _spin_candidates (
    p_id uuid,
    p_cost numeric,
    p_pct numeric,
    p_target numeric,
    p_actual int,
    p_deficit numeric,
    p_weight numeric,
    p_constrained boolean
  ) on commit drop;
  loop
    truncate table _spin_candidates;
    v_eligible_count := 0;
    v_total_weight := 0;
    v_acc := 0;
    v_best_deficit := -999999;
    v_best_deficit_prize := null;
    v_best_cost := null;
    v_won_prize := null;

    for v_item in
      select i.prize_id, i.unit_cost,
             case when p_campaign.snack_launch_active and pz.code='SNACK5' then 85::numeric
                  when p_campaign.snack_launch_active and pz.code='SNACK10' then 15::numeric
                  when coalesce(i.percentage,0)>0 then i.percentage
                  when coalesce(p_config.pool_size,0)>0 then (i.quantity::numeric/p_config.pool_size::numeric)*100.0 else 0 end as pct
        from public.prize_config_items i join public.prizes pz on pz.id=i.prize_id
       where i.config_id=p_config.id and not (i.prize_id=any(v_excluded))
         and (not p_campaign.snack_launch_active or pz.code in ('SNACK5','SNACK10'))
       order by i.unit_cost desc
    loop
      if v_item.pct > 0 then
        v_stock := case when p_campaign.track_inventory then public._available(p_promoter, v_item.prize_id) else 99999 end;
        v_actual := coalesce((v_alloc.awarded->>v_item.prize_id::text)::int, 0);
        v_target := (v_n::numeric * v_item.pct) / 100.0;
        v_deficit := v_target - v_actual::numeric;
        if v_stock > 0 then
          v_eligible_count := v_eligible_count + 1;
          if v_deficit > v_best_deficit then
            v_best_deficit := v_deficit;
            v_best_deficit_prize := v_item.prize_id;
            v_best_cost := v_item.unit_cost;
          end if;
          insert into _spin_candidates values (v_item.prize_id, v_item.unit_cost, v_item.pct, v_target, v_actual, v_deficit, 0, false);
        end if;
      end if;
    end loop;

    if v_eligible_count = 0 then
      raise exception 'OUT_OF_STOCK' using hint = 'No configured prize is available at this promoter.';
    end if;
    -- Restrict randomness to categories within 1.5 prizes of the largest
    -- eligible deficit. This bounds cumulative rounding error while keeping
    -- ties and near-ties random instead of exposing a fixed sequence.
    update _spin_candidates
       set p_constrained = p_deficit < v_best_deficit - 1.5,
           p_weight = (p_pct / 100.0) * exp(greatest(-4.0, least(0.0, (p_deficit - v_best_deficit) / 0.75)));
    select coalesce(sum(p_weight), 0) into v_total_weight from _spin_candidates where not p_constrained;
    if v_total_weight <= 0 then
      update _spin_candidates set p_constrained = false;
      select sum(p_weight) into v_total_weight from _spin_candidates;
    end if;
    v_r := ((('x' || encode(extensions.gen_random_bytes(6), 'hex'))::bit(48)::bigint)::numeric / 281474976710656) * v_total_weight;
    for v_item in select p_id, p_cost, p_weight from _spin_candidates where not p_constrained order by p_id loop
      v_acc := v_acc + v_item.p_weight;
      if v_r < v_acc then
        v_won_prize := v_item.p_id;
        v_won_cost := v_item.p_cost;
        exit;
      end if;
    end loop;
    if v_won_prize is null then
      select p_id, p_cost into v_won_prize, v_won_cost from _spin_candidates where not p_constrained order by p_weight desc limit 1;
    end if;

    -- Reserve before recording the award. The UPDATE is atomic across promoters
    -- and outlets sharing a physical stock row; retry another eligible prize if
    -- another request took the last unit while this draw was being calculated.
    if p_campaign.track_inventory then
      update public.promoter_inventory set reserved = reserved + 1, updated_at = now()
       where promoter_id = p_promoter and prize_id = v_won_prize and on_hand - reserved > 0;
      if not found then
        v_excluded := array_append(v_excluded, v_won_prize);
        v_attempt := v_attempt + 1;
        if v_attempt < 100 then continue; end if;
        raise exception 'OUT_OF_STOCK' using hint = 'No configured prize could be reserved.';
      end if;
    end if;
    exit;
  end loop;

  -- Commit allocation progress atomically
  update public.campaign_allocations
     set total_spins = v_n,
         awarded = jsonb_set(
           awarded,
           array[v_won_prize::text],
           to_jsonb(coalesce((awarded->>v_won_prize::text)::int, 0) + 1)
         ),
         updated_at = now()
   where id = v_alloc.id;

  prize_id := v_won_prize;
  unit_cost := v_won_cost;
  total_spins := v_n;
  return next;
end $$;

create or replace function public.play_spin(p_sale_id uuid, p_spin_no int default 1, p_device_ref text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u public.app_users; s public.sales; c public.campaigns; cfg public.prize_configs; pool public.prize_pools;
  v_existing uuid; v_key text; v_spin_id uuid := gen_random_uuid();
  v_pos int := null; v_prize uuid; v_cost numeric; v_orig uuid := null; v_sub boolean := false;
  pz public.prizes; v_inv_status text; v_alloc_res record;
begin
  u := public._require_promoter();

  select * into s from public.sales where id = p_sale_id for update;
  if s.id is null or s.promoter_id <> u.id then raise exception 'SALE_NOT_FOUND'; end if;

  -- Idempotency: exact same (sale, spin_no) returns existing draw
  select id into v_existing from public.spins where sale_id = s.id and spin_no = p_spin_no;
  if v_existing is not null then return public._spin_json(v_existing) || jsonb_build_object('replayed', true); end if;

  if s.status = 'cancelled' then raise exception 'SALE_CANCELLED'; end if;
  if p_spin_no < 1 or p_spin_no <> s.spins_used + 1 or p_spin_no > s.spins_allowed then
    raise exception 'NO_SPINS_LEFT' using hint = 'This sale has already used its spin.';
  end if;

  select * into c from public.campaigns where id = s.campaign_id for share;
  if c.status <> 'active' then raise exception 'CAMPAIGN_NOT_ACTIVE'; end if;
  cfg := public._active_config(c.id, s.state_id);
  if cfg.id is null then raise exception 'NO_PRIZE_CONFIG'; end if;
  v_key := public._pool_key(c.pool_scope, s);
  if c.snack_launch_active then v_key:=v_key||':snack-launch'; end if;

  -- Perform Controlled Cumulative Random Allocation
  select * into v_alloc_res from public._draw_cumulative_prize(c, cfg, u.id, v_key);
  v_prize := v_alloc_res.prize_id;
  v_cost  := v_alloc_res.unit_cost;

  select * into pz from public.prizes where id = v_prize;
  if pz.id is null then raise exception 'OUT_OF_STOCK'; end if;

  -- _draw_cumulative_prize reserves the unit before committing allocation state.
  if c.track_inventory then
    v_inv_status := 'reserved';
  else
    v_inv_status := 'not_tracked';
  end if;

  insert into public.spins(id, spin_code, sale_id, spin_no, campaign_id, promoter_id, biz_date,
      strategy, pool_id, slot_position, config_id, config_version,
      prize_id, prize_code, prize_name, prize_tier, prize_cost, original_prize_id, substituted,
      inventory_status, device_ref, allocation_phase)
  values (v_spin_id,
      'SPN' || to_char(public.ist_now(),'YYMMDD') || '-' || lpad(nextval('public.spin_code_seq')::text, 6, '0'),
      s.id, p_spin_no, c.id, u.id, public.ist_today(),
      c.draw_strategy, null, null, cfg.id, cfg.version,
      pz.id, pz.code, pz.name, pz.tier, v_cost, v_orig, v_sub,
      v_inv_status, coalesce(p_device_ref, s.device_ref), case when c.snack_launch_active then 'snack_launch' else 'standard' end);

  update public.sales set spins_used = spins_used + 1, status = 'spun' where id = s.id;

  perform public.write_audit('SPIN', 'spins', v_spin_id::text,
    jsonb_build_object('sale_id', s.id, 'prize', pz.code, 'cost', v_cost, 'strategy', c.draw_strategy,
                       'allocation_algorithm', 'cumulative_quota_randomized_near_ties',
                       'allocation_phase', case when c.snack_launch_active then 'snack_launch' else 'standard' end,
                       'config_version', cfg.version, 'outlet_code', s.outlet_code));

  perform public._check_after_spin(v_spin_id);
  return public._spin_json(v_spin_id) || jsonb_build_object('replayed', false);
end $$;

create or replace function public.prize_distribution_report(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u public.app_users; f jsonb := coalesce(p_filters, '{}'::jsonb); v_res jsonb;
begin
  u := public._require_staff();
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into f
    from jsonb_each(f) where value not in ('""'::jsonb, 'null'::jsonb);

  execute format($q$
    with filtered as (
      select sp.* from public.spins sp join public.sales s on s.id = sp.sale_id
       where sp.redemption_status <> 'not_redeemed' and %s
    ), totals as (
      select count(*)::numeric as n from filtered
    ), actual as (
      select prize_id, count(*) as n, sum(prize_cost) as cost,
             count(*) filter (where redemption_status = 'handed_over') as handed,
             count(*) filter (where redemption_status = 'pending') as pending,
             max(prize_name) as label, avg(prize_cost) as unit_cost
        from filtered group by prize_id
    ), targets as (
      select i.prize_id,
             sum(case when f.allocation_phase='snack_launch' then case p.code when 'SNACK5' then 85::numeric when 'SNACK10' then 15::numeric else 0 end else coalesce(nullif(i.percentage,0),case when pc.pool_size>0 then i.quantity::numeric/pc.pool_size*100.0 else 0 end) end) as target_points
        from filtered f
        join public.prize_config_items i on i.config_id = f.config_id
        join public.prize_configs pc on pc.id = f.config_id
        join public.prizes p on p.id=i.prize_id
       group by i.prize_id
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', p.id, 'label', p.name,
      'quantity', coalesce(a.n, 0),
      'unit_cost', round(coalesce(a.unit_cost, p.default_cost), 2),
      'total_cost', coalesce(a.cost, 0),
      'pct', case when t.n > 0 then round(coalesce(a.n, 0)::numeric * 100.0 / t.n, 2) else 0 end,
      'target_pct', case when t.n > 0 then round(coalesce(g.target_points, 0) / t.n, 2) else 0 end,
      'variance_pct', case when t.n > 0 then round(coalesce(a.n, 0)::numeric * 100.0 / t.n - coalesce(g.target_points, 0) / t.n, 2) else 0 end,
      'handed_over', coalesce(a.handed, 0), 'pending', coalesce(a.pending, 0),
      'total_spins', t.n,
      'giveaway_cost', (select coalesce(sum(cost), 0) from actual),
      'avg_giveaway_cost', case when t.n > 0 then round((select coalesce(sum(cost), 0) from actual) / t.n, 2) else 0 end
    ) order by p.sort_order), '[]'::jsonb)
      from public.prizes p cross join totals t
      left join actual a on a.prize_id = p.id
      left join targets g on g.prize_id = p.id
     where p.is_active
  $q$, public._sales_where()) into v_res using f, (u.role = 'admin'), u.id;
  return v_res;
end $$;

revoke execute on function public.prize_distribution_report(jsonb) from public, anon, authenticated;
grant execute on function public.prize_distribution_report(jsonb) to authenticated;


revoke execute on function public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;
