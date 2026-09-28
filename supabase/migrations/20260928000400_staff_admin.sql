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
