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
    update _spin_candidates as candidate
       set p_constrained = candidate.p_deficit < v_best_deficit - 1.5,
           p_weight = (candidate.p_pct / 100.0) * exp(greatest(-4.0, least(0.0, (candidate.p_deficit - v_best_deficit) / 0.75)))
     where candidate.p_id is not null;
    select coalesce(sum(p_weight), 0) into v_total_weight from _spin_candidates where not p_constrained;
    if v_total_weight <= 0 then
      update _spin_candidates as candidate set p_constrained = false where candidate.p_constrained is distinct from false;
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
      update public.promoter_inventory as inv set reserved = inv.reserved + 1, updated_at = now()
       where inv.promoter_id = p_promoter and inv.prize_id = v_won_prize and inv.on_hand - inv.reserved > 0;
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
