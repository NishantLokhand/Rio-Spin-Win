-- Keep supervisor dashboard loads from running a whole-database stale-spin
-- scan. The admin dashboard and the standalone scan RPC retain that behavior.
-- Index the per-sale spin aggregation used below.
create index if not exists spins_sale_id_idx on public.spins(sale_id);

create or replace function public.dashboard_kpis(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; f jsonb; v_tot jsonb; v_prizes jsonb; v_stock jsonb; v_low jsonb; v_flags int; v_budget jsonb;
        v_camp public.campaigns; v_used numeric; v_used_today numeric; v_avg numeric; v_pending int; v_active_now int; v_req int;
        v_admin boolean;
begin
  u := public._require_staff();
  v_admin := u.role = 'admin';
  if v_admin then perform public.run_flag_scan(); end if;
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

-- Resolve outlets for the signed-in organizational employee while preserving
-- the existing promoter-specific exact/additive/MER rules.
create or replace function public.promoter_user_can_access_outlet(p_user_id uuid,p_outlet_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_mode text; v_person public.org_people;
begin
  if not public.is_admin() and p_user_id is distinct from auth.uid()
    and not exists(select 1 from public.promoters pr where pr.user_id=p_user_id and pr.supervisor_id=auth.uid()) then
    return false;
  end if;
  select p.* into v_person from public.org_people p
    where p.auth_user_id=p_user_id and p.active and p.designation in ('PROMOTER','MER','TSE');
  if v_person.id is null then return false; end if;

  if v_person.designation='MER' then
    return exists(
      select 1 from public.outlets o
      cross join lateral jsonb_array_elements_text(coalesce(v_person.beat_override,v_person.beat_values,'[]'::jsonb)) b(value)
      where o.id=p_outlet_id and o.status='active'
        and public.org_match_key(b.value)=public.org_match_key(o.beat)
        and public.org_match_key(o.beat)<>''
    );
  elsif v_person.designation='TSE' then
    return exists(
      select 1 from public.outlets o
      join public.tses t on t.id=o.tse_id
      where o.id=p_outlet_id and o.status='active'
        and (
          (nullif(regexp_replace(coalesce(v_person.mobile,''),'\D','','g'),'') is not null
            and regexp_replace(coalesce(t.mobile,''),'\D','','g')=regexp_replace(v_person.mobile,'\D','','g')
            and (select count(*) from public.tses tm where regexp_replace(coalesce(tm.mobile,''),'\D','','g')=regexp_replace(v_person.mobile,'\D','','g'))=1)
          or (nullif(v_person.fas_id,'') is not null and t.external_ref=v_person.fas_id
            and (select count(*) from public.tses te where te.external_ref=v_person.fas_id)=1)
          or (nullif(v_person.qa_employee_id,'') is not null and t.external_ref=v_person.qa_employee_id
            and (select count(*) from public.tses te where te.external_ref=v_person.qa_employee_id)=1)
          or (nullif(regexp_replace(lower(trim(v_person.employee_name)),'\s+','','g'),'') is not null
            and regexp_replace(lower(trim(t.name)),'\s+','','g')=regexp_replace(lower(trim(v_person.employee_name)),'\s+','','g')
            and (select count(*) from public.tses tn where regexp_replace(lower(trim(tn.name)),'\s+','','g')=regexp_replace(lower(trim(v_person.employee_name)),'\s+','','g'))=1)
        )
    );
  end if;

  select p.outlet_access_mode into v_mode from public.org_people p
    where p.id=v_person.id and p.designation='PROMOTER';
  if v_mode is null then return false; end if;
  if v_mode='workbook_exact' then
    return exists(
      select 1 from public.promoter_outlet_workbook_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active'
      where a.promoter_id=v_person.id and a.source_state='UTTAR PRADESH' and o.id=p_outlet_id
    );
  end if;
  return exists(
    select 1 from public.outlets o where o.id=p_outlet_id and o.status='active' and (
      exists(select 1 from public.promoter_outlet_assignments a where a.promoter_id=v_person.id and a.outlet_id=o.id and a.active)
      or (v_mode='workbook_additive' and exists(select 1 from public.promoter_outlet_workbook_assignments a where a.promoter_id=v_person.id and a.outlet_id=o.id and a.source_state='UTTAR PRADESH'))
      or exists(
        select 1 from (
          select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=v_person.id
          union select v_person.mapped_mer_id where v_person.mapped_mer_id is not null
        ) mapped join public.org_people m on m.id=mapped.mer_id and m.designation='MER' and m.active
        cross join lateral jsonb_array_elements_text(coalesce(m.beat_override,m.beat_values,'[]'::jsonb)) beat(value)
        where public.org_match_key(beat.value)=public.org_match_key(o.beat) and public.org_match_key(o.beat)<>''
      )
    )
  );
end $$;

create or replace function public.get_promoter_outlets()
returns table(id uuid,outlet_code text,name text,area text,city text,tse_id uuid,beat text)
language plpgsql stable security definer set search_path=public as $$
begin
  perform public._require_promoter();
  return query select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
    from public.outlets o where o.status='active' and public.promoter_user_can_access_outlet(auth.uid(),o.id)
    order by o.name;
end $$;

revoke all on function public.dashboard_kpis(jsonb), public.promoter_user_can_access_outlet(uuid,uuid), public.get_promoter_outlets() from public,anon;
grant execute on function public.dashboard_kpis(jsonb), public.promoter_user_can_access_outlet(uuid,uuid), public.get_promoter_outlets() to authenticated;
