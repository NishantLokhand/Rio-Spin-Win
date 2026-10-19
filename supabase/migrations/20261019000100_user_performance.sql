-- Own-login activity for every field designation. Never aggregate team sales.
create or replace function public.report_user_performance(p_filters jsonb default '{}'::jsonb,p_user_type text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare u public.app_users; f jsonb:=coalesce(p_filters,'{}'::jsonb); result jsonb;
begin
  u:=public._require_staff();
  if p_user_type is not null and p_user_type not in ('PROMOTER','TSE','MER') then
    raise exception 'INVALID_USER_TYPE';
  end if;
  select coalesce(jsonb_object_agg(key,value),'{}'::jsonb) into f from jsonb_each(f)
    where value not in ('""'::jsonb,'null'::jsonb);
  execute format($q$
    select coalesce(jsonb_agg(r order by r.spins desc,r.label),'[]'::jsonb) from (
      select s.promoter_id as key,coalesce(max(a.full_name),max(s.promoter_name)) as label,
        case max(p.designation) when 'PROMOTER' then 'Promoter' when 'TSE' then 'TSE' when 'MER' then 'MER' else 'Unknown' end as user_type,
        max(s.promoter_code) as user_code,
        string_agg(distinct nullif(btrim(s.state_name),''),', ' order by nullif(btrim(s.state_name),'')) as state,
        string_agg(distinct nullif(btrim(s.outlet_city),''),', ' order by nullif(btrim(s.outlet_city),'')) as city,
        string_agg(distinct nullif(btrim(s.outlet_area),''),', ' order by nullif(btrim(s.outlet_area),'')) as area,
        string_agg(distinct coalesce(s.outlet_name,'Unnamed outlet') || ' [' || coalesce(s.outlet_code,s.outlet_id::text) || ']', '; '
          order by coalesce(s.outlet_name,'Unnamed outlet') || ' [' || coalesce(s.outlet_code,s.outlet_id::text) || ']') as outlets,
        count(distinct s.outlet_id) as active_outlets,count(*) as sales,
        sum(s.quantity) as units,sum(x.spins) as spins,coalesce(sum(x.cost),0) as giveaway_cost,
        round(coalesce(sum(x.cost),0)/nullif(sum(x.spins),0),2) as avg_cost
      from public.sales s
      left join public.org_people p on p.auth_user_id=s.promoter_id
      left join public.app_users a on a.id=s.promoter_id
      cross join lateral (
        select count(*) as spins,sum(prize_cost) filter(where redemption_status<>'not_redeemed') as cost
        from public.spins where sale_id=s.id
      ) x
      where %s and ($4 is null or p.designation=$4)
      group by s.promoter_id
    ) r
  $q$,public._sales_where()) into result using f,(u.role='admin'),u.id,p_user_type;
  return result;
end $$;
revoke all on function public.report_user_performance(jsonb,text) from public,anon;
grant execute on function public.report_user_performance(jsonb,text) to authenticated;
notify pgrst,'reload schema';
