-- Pause sunglasses and use a snack-only 75/25 distribution for RSW-2026.
-- This is a versioned campaign data change; prior prize configurations and spin
-- history remain intact. Applying it deactivates prior campaign/state configs
-- so every state falls back to this campaign default.
do $$
declare
  v_campaign public.campaigns;
  v_snack5 uuid;
  v_snack10 uuid;
  v_version int;
  v_config uuid;
begin
  select * into strict v_campaign
    from public.campaigns
   where code = 'RSW-2026'
   for update;

  select id into strict v_snack5 from public.prizes where code = 'SNACK5';
  select id into strict v_snack10 from public.prizes where code = 'SNACK10';

  -- Safe if this SQL is run manually before the migration runner sees it.
  if exists (
    select 1 from public.prize_configs
     where campaign_id = v_campaign.id
       and notes = 'Temporary snack-only distribution: 75% ₹5 snacks, 25% ₹10 snacks; sunglasses paused pending senior approval.'
  ) then
    return;
  end if;

  select coalesce(max(version), 0) + 1 into v_version
    from public.prize_configs
   where campaign_id = v_campaign.id;

  update public.prize_configs
     set is_active = false
   where campaign_id = v_campaign.id and is_active;

  insert into public.prize_configs (
    campaign_id, state_id, version, pool_size, total_cost, avg_cost,
    target_cost, exceeds_target, is_active, notes
  ) values (
    v_campaign.id, null, v_version, 200, 1250.00, 6.2500,
    v_campaign.target_cost_per_spin, false, true,
    'Temporary snack-only distribution: 75% ₹5 snacks, 25% ₹10 snacks; sunglasses paused pending senior approval.'
  ) returning id into v_config;

  insert into public.prize_config_items (config_id, prize_id, quantity, unit_cost, percentage)
  values
    (v_config, v_snack5, 150, 5.00, 75.000),
    (v_config, v_snack10, 50, 10.00, 25.000);
end $$;
