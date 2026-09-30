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
           p_weight = (p_pct / 100.0) * exp(greatest(-4.0, least(0.0, (p_deficit - v_best_deficit) / 0.75)))
     where p_id is not null;
    select coalesce(sum(p_weight), 0) into v_total_weight from _spin_candidates where not p_constrained;
    if v_total_weight <= 0 then
      update _spin_candidates set p_constrained = false where p_constrained is distinct from false;
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
