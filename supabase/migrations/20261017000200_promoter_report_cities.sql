-- Cities visited during the filtered period, from immutable sale snapshots.
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
    when 'promoter'    then v_sel := 's.promoter_id as key, s.promoter_name as label, max(s.promoter_code) as promoter_code, max(s.promoter_type::text) as promoter_type, string_agg(distinct s.state_name, '', '') as state, string_agg(distinct s.territory_name, '', '') as territory, string_agg(distinct nullif(btrim(s.outlet_city),''''), '', '' order by nullif(btrim(s.outlet_city),'''')) as city'; v_grp := 's.promoter_id, s.promoter_name';
    when 'product'     then v_sel := 's.product_id as key, s.product_name as label, max(s.sku_code) as sku_code'; v_grp := 's.product_id, s.product_name';
    when 'date'        then v_sel := 's.biz_date as key, to_char(s.biz_date, ''DD Mon YYYY'') as label'; v_grp := 's.biz_date';
    when 'area' then v_sel := 'coalesce(s.outlet_area,''—'') as key, coalesce(s.outlet_area,''—'') as label'; v_grp := 's.outlet_area';
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


notify pgrst,'reload schema';
