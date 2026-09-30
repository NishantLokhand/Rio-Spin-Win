-- Fix the prize draw's temporary-table updates for databases enforcing filtered UPDATE statements.
-- The candidate set is intentionally updated in full, so filter by its guaranteed non-null prize id.
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
