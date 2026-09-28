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
