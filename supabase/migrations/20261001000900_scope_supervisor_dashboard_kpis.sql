-- Index supervisor-scoped dashboard aggregates by their date/status and owner.
create index if not exists promoter_sessions_work_date_promoter_idx
  on public.promoter_sessions(work_date, promoter_id);
create index if not exists activity_flags_open_promoter_idx
  on public.activity_flags(promoter_id) where status='open';
create index if not exists outlet_requests_pending_promoter_idx
  on public.outlet_requests(promoter_id) where status='pending';

-- Keep the KPI response shape unchanged while filtering supervisor-only tables
-- through one small promoter-id set instead of repeated per-row access checks.
create or replace function public.dashboard_kpis(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.app_users; f jsonb; v_tot jsonb; v_prizes jsonb; v_stock jsonb; v_low jsonb; v_flags int; v_budget jsonb;
        v_camp public.campaigns; v_used numeric; v_used_today numeric; v_avg numeric; v_pending int; v_active_now int; v_req int;
        v_admin boolean; v_promoter_ids uuid[];
begin
  u := public._require_staff();
  v_admin := u.role = 'admin';
  if v_admin then
    perform public.run_flag_scan();
  else
    select coalesce(array_agg(pr.user_id), '{}'::uuid[]) into v_promoter_ids
      from public.promoters pr where pr.supervisor_id=u.id;
  end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into f
    from jsonb_each(coalesce(p_filters,'{}'::jsonb)) where value not in ('""'::jsonb, 'null'::jsonb);

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
    into v_stock from public.prizes p left join (
      select i.prize_id, sum(i.on_hand) on_hand, sum(i.reserved) reserved from public.promoter_inventory i
       where (v_admin or i.promoter_id=any(v_promoter_ids))
         and (f->>'promoter_id' is null or i.promoter_id=(f->>'promoter_id')::uuid)
       group by i.prize_id) q on q.prize_id=p.id where p.is_active;

  select coalesce(jsonb_agg(jsonb_build_object('promoter_id', i.promoter_id, 'promoter', au.full_name, 'prize', p.short_name,
                 'on_hand', i.on_hand, 'threshold', p.low_stock_threshold) order by i.on_hand, au.full_name), '[]'::jsonb)
    into v_low from public.promoter_inventory i join public.prizes p on p.id=i.prize_id
      join public.app_users au on au.id=i.promoter_id
   where au.is_active and p.is_active and i.on_hand<=p.low_stock_threshold
     and (v_admin or i.promoter_id=any(v_promoter_ids));

  select count(*) into v_flags from public.activity_flags
   where status='open' and ((promoter_id is null and v_admin) or v_admin or promoter_id=any(v_promoter_ids));
  select count(*) into v_pending from public.spins
   where redemption_status='pending' and (v_admin or promoter_id=any(v_promoter_ids));
  select count(*) into v_active_now from public.promoter_sessions
   where work_date=public.ist_today() and (v_admin or promoter_id=any(v_promoter_ids));
  select count(*) into v_req from public.outlet_requests
   where status='pending' and (v_admin or promoter_id=any(v_promoter_ids));

  select * into v_camp from public.campaigns
   where (f->>'campaign_id' is null and status='active') or id=(f->>'campaign_id')::uuid
   order by created_at desc limit 1;
  if v_camp.id is not null then
    select coalesce(sum(prize_cost),0), coalesce(sum(prize_cost) filter (where biz_date=public.ist_today()),0), avg(prize_cost)
      into v_used, v_used_today, v_avg
      from public.spins where campaign_id=v_camp.id and redemption_status<>'not_redeemed';
    v_budget := jsonb_build_object('campaign_id',v_camp.id,'campaign',v_camp.name,
      'total_budget',v_camp.total_budget,'used',v_used,
      'remaining',case when v_camp.total_budget is null then null else v_camp.total_budget-v_used end,
      'daily_budget',v_camp.daily_budget,'used_today',v_used_today,
      'avg_cost',round(coalesce(v_avg,v_camp.target_cost_per_spin),2),
      'target',v_camp.target_cost_per_spin,
      'est_spins_remaining',case when v_camp.total_budget is null then null
            else floor((v_camp.total_budget-v_used)/nullif(coalesce(v_avg,v_camp.target_cost_per_spin),0)) end,
      'state_budgets',(select jsonb_agg(jsonb_build_object('state',st.name,'budget',cs.budget,
            'used',(select coalesce(sum(sp.prize_cost),0) from public.spins sp join public.sales sa on sa.id=sp.sale_id
                    where sp.campaign_id=v_camp.id and sa.state_id=cs.state_id and sp.redemption_status<>'not_redeemed')))
          from public.campaign_states cs join public.states st on st.id=cs.state_id
          where cs.campaign_id=v_camp.id and cs.budget is not null));
  end if;

  return jsonb_build_object('totals',v_tot,'prizes',v_prizes,'stock',v_stock,'low_stock',v_low,
    'open_flags',v_flags,'pending_handovers',v_pending,'promoters_on_duty',v_active_now,
    'pending_outlet_requests',v_req,'budget',v_budget,'biz_date',public.ist_today());
end $$;

revoke all on function public.dashboard_kpis(jsonb) from public,anon;
grant execute on function public.dashboard_kpis(jsonb) to authenticated;
