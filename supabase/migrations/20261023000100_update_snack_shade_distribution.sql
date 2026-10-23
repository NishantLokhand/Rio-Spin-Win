-- Update the active Rio Spin & Win allocation.
--
-- The base campaign now uses 70% ₹5 snacks, 24% ₹10 snacks and 6% Rio
-- Shades. Rio Shades remain inventory-gated by the existing draw engine:
-- promoters without shade stock are never eligible for shade slots, while
-- promoters with shade stock can receive them.
--
-- Inventory-gated allocation is intentionally non-blocking for an unavailable
-- prize so a promoter can continue while at least one eligible prize remains.
do $$
declare
  c record;
  cfg record;
  shade_id uuid;
  snack5_id uuid;
  snack10_id uuid;
  admin_id uuid;
  next_version int;
  pool_size int := 100;
  total_cost numeric;
begin
  select * into c from public.campaigns where code = 'RSW-2026' limit 1;
  if c.id is null then
    raise exception 'Base campaign RSW-2026 was not found';
  end if;

  select id into snack5_id from public.prizes where code = 'SNACK5';
  select id into snack10_id from public.prizes where code = 'SNACK10';
  select id into shade_id from public.prizes where code = 'SHADES';
  if snack5_id is null or snack10_id is null or shade_id is null then
    raise exception 'SNACK5, SNACK10 and SHADES prizes must exist before updating distribution';
  end if;

  select id into admin_id from public.app_users where role = 'admin' order by created_at limit 1;
  total_cost :=
      70 * (select default_cost from public.prizes where id = snack5_id)
    + 24 * (select default_cost from public.prizes where id = snack10_id)
    +  6 * (select default_cost from public.prizes where id = shade_id);

  update public.prize_configs
     set is_active = false
   where campaign_id = c.id and is_active;

  select coalesce(max(version), 0) + 1 into next_version
    from public.prize_configs where campaign_id = c.id;

  insert into public.prize_configs(
      campaign_id, state_id, version, pool_size, total_cost, avg_cost,
      target_cost, exceeds_target, override_by, is_active, notes, created_by)
  values(
      c.id, null, next_version, pool_size, total_cost, total_cost / pool_size,
      c.target_cost_per_spin, total_cost / pool_size > c.target_cost_per_spin,
      admin_id, true,
      'Updated allocation: 70% ₹5, 24% ₹10, 6% Rio Shades; shades are inventory-gated',
      admin_id)
  returning id into cfg;

  insert into public.prize_config_items(config_id, prize_id, quantity, unit_cost, percentage)
  values
    (cfg.id, snack5_id, 70, (select default_cost from public.prizes where id = snack5_id), 70),
    (cfg.id, snack10_id, 24, (select default_cost from public.prizes where id = snack10_id), 24),
    (cfg.id, shade_id,   6, (select default_cost from public.prizes where id = shade_id), 6);

  -- The previous temporary launch guard required both snacks to be stocked.
  -- Disable it and let the existing inventory-aware allocator continue with
  -- whichever configured prizes are available for that promoter.
  update public.campaigns
     set snack_launch_active = false,
         oos_mode = 'defer',
         config_change_mode = 'regenerate_now',
         updated_at = now()
   where id = c.id;

  notify pgrst, 'reload schema';
end $$;
