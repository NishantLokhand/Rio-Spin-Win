-- RSW-2026 uses the 70/24/6 structure only across campaign spins where
-- sunglasses are available to the promoter. Other RSW-2026 spins use 75/25.
-- Historical spin rows are preserved; new cohort counters start at zero.

alter table public.campaign_allocations
  add column if not exists shade_eligible_spins integer not null default 0,
  add column if not exists shade_eligible_awarded jsonb not null default '{}'::jsonb,
  add column if not exists shade_ineligible_spins integer not null default 0,
  add column if not exists shade_ineligible_awarded jsonb not null default '{}'::jsonb;

alter table public.spins
  add column if not exists shade_eligible_at_draw boolean;

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
  v_cohort_n int;
  v_cohort_awarded jsonb;
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
  v_best_deficit numeric := -999999;
  v_excluded uuid[] := '{}'::uuid[];
  v_attempt int := 0;
  v_special_campaign boolean := p_campaign.code = 'RSW-2026';
  v_shade_id uuid;
  v_shades_configured boolean := false;
  v_shade_eligible boolean := false;
begin
  -- The RSW campaign scope lock makes cohort totals shared across promoters.
  perform pg_advisory_xact_lock(hashtext('rio_alloc:' || p_campaign.id::text || ':' || p_campaign.pool_scope::text || ':' || p_key));

  if p_campaign.snack_launch_active and p_campaign.track_inventory and exists (
    select 1 from public.prizes p
     where p.code in ('SNACK5','SNACK10') and public._available(p_promoter,p.id) <= 0
  ) then
    raise exception 'OUT_OF_STOCK' using hint='Both snack prizes must be in stock during the temporary launch phase.';
  end if;

  if p_campaign.track_inventory and p_campaign.oos_mode = 'block' and exists (
    select 1 from public.prize_config_items i join public.prizes p on p.id=i.prize_id
     where i.config_id = p_config.id
       and (not p_campaign.snack_launch_active or p.code in ('SNACK5','SNACK10'))
       and coalesce(nullif(i.percentage, 0), i.quantity::numeric / p_config.pool_size * 100.0) > 0
       and public._available(p_promoter, i.prize_id) <= 0
  ) then
    raise exception 'OUT_OF_STOCK' using hint = 'Prize stock is temporarily unavailable. Please contact the supervisor.';
  end if;

  if v_special_campaign then
    select id into v_shade_id from public.prizes where code = 'SHADES';
    select exists (
      select 1 from public.prize_config_items i
       where i.config_id = p_config.id and i.prize_id = v_shade_id
         and coalesce(nullif(i.percentage, 0), i.quantity::numeric / p_config.pool_size * 100.0) > 0
    ) into v_shades_configured;
    v_shade_eligible := v_shades_configured
      and (not p_campaign.track_inventory or public._available(p_promoter, v_shade_id) > 0);
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
    v_won_prize := null;

    if v_special_campaign then
      if v_shade_eligible then
        v_cohort_n := v_alloc.shade_eligible_spins + 1;
        v_cohort_awarded := v_alloc.shade_eligible_awarded;
      else
        v_cohort_n := v_alloc.shade_ineligible_spins + 1;
        v_cohort_awarded := v_alloc.shade_ineligible_awarded;
      end if;
    else
      v_cohort_n := v_n;
      v_cohort_awarded := v_alloc.awarded;
    end if;

    for v_item in
      select i.prize_id, i.unit_cost, pz.code,
             case
               when v_special_campaign and v_shade_eligible then
                 coalesce(nullif(i.percentage,0), case when p_config.pool_size > 0 then i.quantity::numeric / p_config.pool_size::numeric * 100.0 else 0 end)
               when v_special_campaign and not v_shade_eligible and pz.code = 'SNACK5' then 75::numeric
               when v_special_campaign and not v_shade_eligible and pz.code = 'SNACK10' then 25::numeric
               when v_special_campaign then 0::numeric
               when p_campaign.snack_launch_active and pz.code = 'SNACK5' then 85::numeric
               when p_campaign.snack_launch_active and pz.code = 'SNACK10' then 15::numeric
               else coalesce(nullif(i.percentage,0), case when p_config.pool_size > 0 then i.quantity::numeric / p_config.pool_size::numeric * 100.0 else 0 end)
             end as pct
        from public.prize_config_items i
        join public.prizes pz on pz.id = i.prize_id
       where i.config_id = p_config.id and not (i.prize_id = any(v_excluded))
         and (not p_campaign.snack_launch_active or pz.code in ('SNACK5','SNACK10'))
       order by i.unit_cost desc
    loop
      if v_item.pct > 0 then
        v_stock := case when p_campaign.track_inventory then public._available(p_promoter, v_item.prize_id) else 99999 end;
        v_actual := coalesce((v_cohort_awarded->>v_item.prize_id::text)::int, 0);
        v_target := (v_cohort_n::numeric * v_item.pct) / 100.0;
        v_deficit := v_target - v_actual::numeric;
        if v_stock > 0 then
          v_eligible_count := v_eligible_count + 1;
          if v_deficit > v_best_deficit then v_best_deficit := v_deficit; end if;
          insert into _spin_candidates values (v_item.prize_id, v_item.unit_cost, v_item.pct, v_target, v_actual, v_deficit, 0, false);
        end if;
      end if;
    end loop;

    if v_eligible_count = 0 then
      raise exception 'OUT_OF_STOCK' using hint = 'No configured prize is available at this promoter.';
    end if;

    update _spin_candidates as candidate
       set p_constrained = candidate.p_deficit < v_best_deficit - 1.5,
           p_weight = (candidate.p_pct / 100.0) * exp(greatest(-4.0, least(0.0, (candidate.p_deficit - v_best_deficit) / 0.75)));
    select coalesce(sum(p_weight), 0) into v_total_weight from _spin_candidates where not p_constrained;
    if v_total_weight <= 0 then
      update _spin_candidates set p_constrained = false where p_constrained is distinct from false;
      select coalesce(sum(p_weight), 0) into v_total_weight from _spin_candidates;
    end if;

    v_r := ((('x' || encode(extensions.gen_random_bytes(6), 'hex'))::bit(48)::bigint)::numeric / 281474976710656) * v_total_weight;
    for v_item in select p_id, p_cost, p_weight from _spin_candidates where not p_constrained order by p_id loop
      v_acc := v_acc + v_item.p_weight;
      if v_r < v_acc then v_won_prize := v_item.p_id; v_won_cost := v_item.p_cost; exit; end if;
    end loop;
    if v_won_prize is null then
      select p_id, p_cost into v_won_prize, v_won_cost from _spin_candidates where not p_constrained order by p_weight desc limit 1;
    end if;

    if p_campaign.track_inventory then
      update public.promoter_inventory as inv set reserved = inv.reserved + 1, updated_at = now()
       where inv.promoter_id = p_promoter and inv.prize_id = v_won_prize and inv.on_hand - inv.reserved > 0;
      if not found then
        v_attempt := v_attempt + 1;
        if v_special_campaign and v_shade_eligible and v_won_prize = v_shade_id then
          -- Stock disappeared during reservation: count this draw in the no-shades cohort.
          v_shade_eligible := false;
          v_excluded := '{}'::uuid[];
        else
          v_excluded := array_append(v_excluded, v_won_prize);
        end if;
        if v_attempt < 100 then continue; end if;
        raise exception 'OUT_OF_STOCK' using hint = 'No configured prize could be reserved.';
      end if;
    end if;
    exit;
  end loop;

  perform set_config('rio.shade_eligible_draw',
    case when not v_special_campaign then 'na' when v_shade_eligible then 'true' else 'false' end, true);

  update public.campaign_allocations
     set total_spins = v_n,
         awarded = jsonb_set(awarded, array[v_won_prize::text], to_jsonb(coalesce((awarded->>v_won_prize::text)::int, 0) + 1)),
         shade_eligible_spins = shade_eligible_spins + case when v_special_campaign and v_shade_eligible then 1 else 0 end,
         shade_eligible_awarded = case when v_special_campaign and v_shade_eligible
           then jsonb_set(shade_eligible_awarded, array[v_won_prize::text], to_jsonb(coalesce((shade_eligible_awarded->>v_won_prize::text)::int, 0) + 1))
           else shade_eligible_awarded end,
         shade_ineligible_spins = shade_ineligible_spins + case when v_special_campaign and not v_shade_eligible then 1 else 0 end,
         shade_ineligible_awarded = case when v_special_campaign and not v_shade_eligible
           then jsonb_set(shade_ineligible_awarded, array[v_won_prize::text], to_jsonb(coalesce((shade_ineligible_awarded->>v_won_prize::text)::int, 0) + 1))
           else shade_ineligible_awarded end,
         updated_at = now()
   where id = v_alloc.id;

  prize_id := v_won_prize;
  unit_cost := v_won_cost;
  total_spins := v_n;
  return next;
end $$;

revoke execute on function public._draw_cumulative_prize(public.campaigns, public.prize_configs, uuid, text) from public, anon, authenticated;

-- Record the exact eligibility decision on each spin for accurate reporting.
create or replace function public.play_spin(p_sale_id uuid, p_spin_no int default 1, p_device_ref text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u public.app_users; s public.sales; c public.campaigns; cfg public.prize_configs;
  v_existing uuid; v_key text; v_spin_id uuid := gen_random_uuid();
  v_prize uuid; v_cost numeric; v_orig uuid := null; v_sub boolean := false;
  pz public.prizes; v_inv_status text; v_alloc_res record; v_shade_eligible boolean;
  v_eligibility_setting text;
begin
  u := public._require_promoter();
  select * into s from public.sales where id = p_sale_id for update;
  if s.id is null or s.promoter_id <> u.id then raise exception 'SALE_NOT_FOUND'; end if;

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
  if c.snack_launch_active then v_key := v_key || ':snack-launch'; end if;

  select * into v_alloc_res from public._draw_cumulative_prize(c, cfg, u.id, v_key);
  v_prize := v_alloc_res.prize_id;
  v_cost := v_alloc_res.unit_cost;
  v_eligibility_setting := current_setting('rio.shade_eligible_draw', true);
  if v_eligibility_setting in ('true','false') then
    v_shade_eligible := v_eligibility_setting = 'true';
  else
    v_shade_eligible := null;
  end if;

  select * into pz from public.prizes where id = v_prize;
  if pz.id is null then raise exception 'OUT_OF_STOCK'; end if;
  v_inv_status := case when c.track_inventory then 'reserved' else 'not_tracked' end;

  insert into public.spins(id, spin_code, sale_id, spin_no, campaign_id, promoter_id, biz_date,
      strategy, pool_id, slot_position, config_id, config_version,
      prize_id, prize_code, prize_name, prize_tier, prize_cost, original_prize_id, substituted,
      inventory_status, device_ref, allocation_phase, shade_eligible_at_draw)
  values (v_spin_id,
      'SPN' || to_char(public.ist_now(),'YYMMDD') || '-' || lpad(nextval('public.spin_code_seq')::text, 6, '0'),
      s.id, p_spin_no, c.id, u.id, public.ist_today(),
      c.draw_strategy, null, null, cfg.id, cfg.version,
      pz.id, pz.code, pz.name, pz.tier, v_cost, v_orig, v_sub,
      v_inv_status, coalesce(p_device_ref, s.device_ref), case when c.snack_launch_active then 'snack_launch' else 'standard' end,
      v_shade_eligible);

  update public.sales set spins_used = spins_used + 1, status = 'spun' where id = s.id;
  perform public.write_audit('SPIN', 'spins', v_spin_id::text,
    jsonb_build_object('sale_id', s.id, 'prize', pz.code, 'cost', v_cost, 'strategy', c.draw_strategy,
                       'allocation_algorithm', 'cumulative_quota_randomized_near_ties',
                       'allocation_phase', case when c.snack_launch_active then 'snack_launch' else 'standard' end,
                       'shade_eligible_at_draw', v_shade_eligible,
                       'config_version', cfg.version, 'outlet_code', s.outlet_code));
  perform public._check_after_spin(v_spin_id);
  return public._spin_json(v_spin_id) || jsonb_build_object('replayed', false);
end $$;

-- Install the temporary senior-approved configuration for the real campaign.
do $$
declare
  v_campaign public.campaigns;
  v_snack5 uuid; v_snack10 uuid; v_shades uuid;
  v_cost5 numeric; v_cost10 numeric; v_shade_cost numeric;
  v_admin uuid; v_version int; v_config uuid; v_avg numeric;
  v_note text := 'Temporary eligible-shade allocation: 70% ₹5, 24% ₹10, 6% shades across all campaign spins with shade stock; no-stock fallback 75/25. Review Monday.';
begin
  select * into strict v_campaign from public.campaigns where code = 'RSW-2026' for update;
  select id, default_cost into strict v_snack5, v_cost5 from public.prizes where code = 'SNACK5';
  select id, default_cost into strict v_snack10, v_cost10 from public.prizes where code = 'SNACK10';
  select id, default_cost into strict v_shades, v_shade_cost from public.prizes where code = 'SHADES';
  select id into v_admin from public.app_users where role = 'admin' order by created_at limit 1;

  update public.campaigns set
    pool_scope = 'campaign', track_inventory = true, snack_launch_active = false,
    oos_mode = 'defer', config_change_mode = 'regenerate_now', target_cost_per_spin = 12,
    updated_at = now()
  where id = v_campaign.id;

  if exists (select 1 from public.prize_configs where campaign_id = v_campaign.id and notes = v_note) then
    return;
  end if;

  v_avg := round((70 * v_cost5 + 24 * v_cost10 + 6 * v_shade_cost) / 100.0, 4);
  if v_avg > 12 then raise exception 'Configured prize costs produce ₹% per eligible spin, above the temporary ₹12 cap', v_avg; end if;

  update public.prize_configs set is_active = false where campaign_id = v_campaign.id and is_active;
  select coalesce(max(version), 0) + 1 into v_version from public.prize_configs where campaign_id = v_campaign.id;
  insert into public.prize_configs(campaign_id, state_id, version, pool_size, total_cost, avg_cost,
      target_cost, exceeds_target, override_by, is_active, notes, created_by)
  values (v_campaign.id, null, v_version, 100, round(v_avg * 100, 2), v_avg,
      12, false, null, true, v_note, v_admin)
  returning id into v_config;

  insert into public.prize_config_items(config_id, prize_id, quantity, unit_cost, percentage)
  values (v_config, v_snack5, 70, v_cost5, 70),
         (v_config, v_snack10, 24, v_cost10, 24),
         (v_config, v_shades, 6, v_shade_cost, 6);
end $$;

-- Report campaign-wide targets using each spin's actual stock-eligibility cohort.
create or replace function public.pool_status(p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_configs jsonb; v_distribution jsonb;
  v_total_spins int := 0; v_giveaway_cost numeric := 0; v_avg_cost numeric := 0;
  v_cfg_id uuid; v_target_cost numeric := 10.0;
begin
  perform public._require_admin();
  select coalesce(jsonb_agg(jsonb_build_object(
      'config_id', pc.id, 'version', pc.version, 'state_id', pc.state_id, 'state_name', st.name,
      'pool_size', pc.pool_size, 'total_cost', pc.total_cost, 'avg_cost', round(pc.avg_cost,2),
      'target', pc.target_cost, 'exceeds_target', pc.exceeds_target, 'created_at', pc.created_at,
      'items', (select jsonb_agg(jsonb_build_object('prize_id', i.prize_id, 'name', p.name, 'short_name', p.short_name,
                     'tier', p.tier, 'percentage', coalesce(i.percentage, round(i.quantity::numeric / pc.pool_size * 100.0, 2)),
                     'quantity', i.quantity, 'unit_cost', i.unit_cost) order by i.unit_cost)
                  from public.prize_config_items i join public.prizes p on p.id = i.prize_id where i.config_id = pc.id)
    ) order by pc.state_id nulls first), '[]'::jsonb)
    into v_configs from public.prize_configs pc left join public.states st on st.id = pc.state_id
   where pc.campaign_id = p_campaign and pc.is_active;

  select count(*) filter (where redemption_status <> 'not_redeemed'),
         coalesce(sum(prize_cost) filter (where redemption_status <> 'not_redeemed'), 0)
    into v_total_spins, v_giveaway_cost from public.spins where campaign_id = p_campaign;
  v_avg_cost := case when v_total_spins > 0 then round(v_giveaway_cost / v_total_spins, 2) else 0 end;

  select id, target_cost into v_cfg_id, v_target_cost from public.prize_configs
   where campaign_id = p_campaign and is_active and state_id is null limit 1;

  with actual_awards as (
    select prize_id, count(*) as actual_count, avg(prize_cost) as unit_cost, sum(prize_cost) as total_prize_cost
      from public.spins where campaign_id = p_campaign and redemption_status <> 'not_redeemed' group by prize_id
  ), cfg_items as (
    select i.prize_id, p.name, p.short_name, p.tier, i.unit_cost,
           coalesce(nullif(i.percentage,0), case when pc.pool_size > 0 then i.quantity::numeric / pc.pool_size * 100.0 else 0 end) as target_pct
      from public.prize_configs pc join public.prize_config_items i on i.config_id = pc.id
      join public.prizes p on p.id = i.prize_id where pc.id = v_cfg_id
  ), target_awards as (
    select i.prize_id,
      sum(case
        when sp.shade_eligible_at_draw is true then case p.code when 'SNACK5' then 70 when 'SNACK10' then 24 when 'SHADES' then 6 else 0 end
        when sp.shade_eligible_at_draw is false then case p.code when 'SNACK5' then 75 when 'SNACK10' then 25 else 0 end
        when sp.allocation_phase = 'snack_launch' then case p.code when 'SNACK5' then 85 when 'SNACK10' then 15 else 0 end
        else coalesce(nullif(i.percentage,0), case when pc.pool_size > 0 then i.quantity::numeric / pc.pool_size * 100.0 else 0 end)
      end / 100.0) as target_count
      from public.spins sp join public.prize_config_items i on i.config_id = sp.config_id
      join public.prize_configs pc on pc.id = sp.config_id join public.prizes p on p.id = i.prize_id
     where sp.campaign_id = p_campaign and sp.redemption_status <> 'not_redeemed' group by i.prize_id
  ), prize_catalog as (
    select p.id as prize_id, p.name, p.short_name, p.tier, coalesce(ci.unit_cost, aa.unit_cost, p.default_cost) as unit_cost,
           coalesce(ci.target_pct,0) as current_target_pct, coalesce(ta.target_count,0) as target_count,
           coalesce(aa.actual_count,0) as actual_count, coalesce(aa.total_prize_cost,0) as total_prize_cost
      from public.prizes p left join cfg_items ci on ci.prize_id=p.id left join actual_awards aa on aa.prize_id=p.id
      left join target_awards ta on ta.prize_id=p.id
     where p.is_active and (ci.prize_id is not null or aa.prize_id is not null or ta.prize_id is not null)
  )
  select jsonb_build_object('total_spins',v_total_spins,'giveaway_cost',v_giveaway_cost,'avg_giveaway_cost',v_avg_cost,
      'target_cost',v_target_cost,'items',coalesce(jsonb_agg(jsonb_build_object(
        'prize_id',pc.prize_id,'name',pc.name,'short_name',pc.short_name,'tier',pc.tier,'unit_cost',pc.unit_cost,
        'target_pct',case when v_total_spins>0 then round(pc.target_count*100.0/v_total_spins,2) else round(pc.current_target_pct,2) end,
        'target_count',round(pc.target_count,1),'actual_count',pc.actual_count,
        'actual_pct',case when v_total_spins>0 then round(pc.actual_count::numeric*100.0/v_total_spins,2) else 0 end,
        'variance_pct',case when v_total_spins>0 then round(pc.actual_count::numeric*100.0/v_total_spins-pc.target_count*100.0/v_total_spins,2) else 0 end,
        'total_cost',pc.total_prize_cost) order by pc.unit_cost),'[]'::jsonb)) into v_distribution from prize_catalog pc;

  return jsonb_build_object('configs',v_configs,'distribution',v_distribution,'pools','[]'::jsonb,
    'totals',jsonb_build_object('total_spins_all_pools',v_total_spins,'used',v_total_spins,'giveaway_cost',v_giveaway_cost,'avg_cost',v_avg_cost));
end $$;

create or replace function public.prize_distribution_report(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u public.app_users; f jsonb := coalesce(p_filters, '{}'::jsonb); v_res jsonb;
begin
  u := public._require_staff();
  select coalesce(jsonb_object_agg(key,value),'{}'::jsonb) into f from jsonb_each(f) where value not in ('""'::jsonb,'null'::jsonb);
  execute format($q$
    with filtered as (
      select sp.* from public.spins sp join public.sales s on s.id=sp.sale_id
       where sp.redemption_status <> 'not_redeemed' and %s
    ), totals as (select count(*)::numeric as n from filtered),
    actual as (
      select prize_id,count(*) as n,sum(prize_cost) as cost,
             count(*) filter (where redemption_status='handed_over') as handed,
             count(*) filter (where redemption_status='pending') as pending,
             max(prize_name) as label,avg(prize_cost) as unit_cost
        from filtered group by prize_id
    ), targets as (
      select i.prize_id,sum(case
        when f.shade_eligible_at_draw is true then case p.code when 'SNACK5' then 70 when 'SNACK10' then 24 when 'SHADES' then 6 else 0 end
        when f.shade_eligible_at_draw is false then case p.code when 'SNACK5' then 75 when 'SNACK10' then 25 else 0 end
        when f.allocation_phase='snack_launch' then case p.code when 'SNACK5' then 85 when 'SNACK10' then 15 else 0 end
        else coalesce(nullif(i.percentage,0),case when pc.pool_size>0 then i.quantity::numeric/pc.pool_size*100.0 else 0 end)
      end) as target_points
        from filtered f join public.prize_config_items i on i.config_id=f.config_id
        join public.prize_configs pc on pc.id=f.config_id join public.prizes p on p.id=i.prize_id group by i.prize_id
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'key',p.id,'label',p.name,'quantity',coalesce(a.n,0),
      'unit_cost',round(coalesce(a.unit_cost,p.default_cost),2),'total_cost',coalesce(a.cost,0),
      'pct',case when t.n>0 then round(coalesce(a.n,0)::numeric*100.0/t.n,2) else 0 end,
      'target_pct',case when t.n>0 then round(coalesce(g.target_points,0)/t.n,2) else 0 end,
      'variance_pct',case when t.n>0 then round(coalesce(a.n,0)::numeric*100.0/t.n-coalesce(g.target_points,0)/t.n,2) else 0 end,
      'handed_over',coalesce(a.handed,0),'pending',coalesce(a.pending,0),'total_spins',t.n,
      'giveaway_cost',(select coalesce(sum(cost),0) from actual),
      'avg_giveaway_cost',case when t.n>0 then round((select coalesce(sum(cost),0) from actual)/t.n,2) else 0 end
    ) order by p.sort_order),'[]'::jsonb)
      from public.prizes p cross join totals t left join actual a on a.prize_id=p.id left join targets g on g.prize_id=p.id
     where p.is_active
  $q$, public._sales_where()) into v_res using f,(u.role='admin'),u.id;
  return v_res;
end $$;

notify pgrst, 'reload schema';
