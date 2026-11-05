-- Transactions tab only. Adds one SELECT-only RPC; existing views, functions,
-- tables, policies, prize rules and all recorded activity remain unchanged.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function public.transaction_report_page(
  p_filters jsonb default '{}'::jsonb,
  p_after_bill uuid default null,
  p_as_of timestamptz default null,
  p_limit integer default 250
) returns jsonb
language sql stable security invoker
set search_path = public
as $report$
  with parameters as materialized (
    select coalesce(p_filters,'{}'::jsonb) as f,
      coalesce(p_as_of,statement_timestamp()) as as_of,
      greatest(1,least(coalesce(p_limit,250),250)) as page_size,
      array(select e.user_id::uuid from jsonb_array_elements_text(public.get_reporting_excluded_users()) as e(user_id)) as excluded
  ), selected as materialized (
    select s.* from public.sales s cross join parameters p
    where public.is_staff()
      and (p_after_bill is null or s.id > p_after_bill)
      and s.created_at <= p.as_of
      and not (s.promoter_id = any(p.excluded))
      and (nullif(p.f->>'date_from','') is null or s.biz_date >= (p.f->>'date_from')::date)
      and (nullif(p.f->>'date_to','') is null or s.biz_date <= (p.f->>'date_to')::date)
      and (nullif(p.f->>'campaign_id','') is null or s.campaign_id = (p.f->>'campaign_id')::uuid)
      and (nullif(p.f->>'state_id','') is null or s.state_id = (p.f->>'state_id')::uuid)
      and (nullif(p.f->>'territory_id','') is null or s.territory_id = (p.f->>'territory_id')::uuid)
      and (nullif(p.f->>'tse_id','') is null or s.tse_id = (p.f->>'tse_id')::uuid)
      and (nullif(p.f->>'outlet_id','') is null or s.outlet_id = (p.f->>'outlet_id')::uuid)
      and (nullif(p.f->>'promoter_id','') is null or s.promoter_id = (p.f->>'promoter_id')::uuid)
      and (nullif(p.f->>'area','') is null or s.outlet_area = p.f->>'area')
      and (nullif(p.f->>'city','') is null or s.outlet_city = p.f->>'city')
      and (nullif(p.f->>'distributor','') is null or s.distributor = p.f->>'distributor')
      and (nullif(p.f->>'product_id','') is null or exists (
        select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=(p.f->>'product_id')::uuid
      ) or (not exists(select 1 from public.sale_items si where si.sale_id=s.id)
        and s.product_id=(p.f->>'product_id')::uuid))
    order by s.id
    limit (select page_size+1 from parameters)
  ), page as materialized (
    select * from selected order by id limit (select page_size from parameters)
  ), bills as (
    select s.id as transaction_id,c.code as campaign_code,s.campaign_id,
      s.biz_date as bill_date,s.created_at as bill_created_at,
      (s.created_at at time zone 'Asia/Kolkata')::date as bill_recorded_date,
      to_char(s.created_at at time zone 'Asia/Kolkata','HH24:MI:SS') as bill_time,
      s.state_name as state,s.state_id,s.territory_name as territory,s.territory_id,
      s.tse_id,s.tse_code,s.tse_name,s.outlet_id,s.outlet_code,s.outlet_name,
      s.outlet_license_no,s.outlet_address,s.outlet_area as area,s.outlet_city as city,s.distributor,
      s.promoter_id,s.promoter_code,s.promoter_name,s.promoter_type,s.device_ref,
      s.quantity as bill_quantity,s.spins_allowed,s.spins_used as stored_spins_used,
      s.status as sale_status,s.cancelled_reason,
      coalesce(items.rows,jsonb_build_array(jsonb_build_object(
        'product_id',s.product_id,'sku_code',s.sku_code,'product_name',s.product_name,'quantity',s.quantity
      ))) as items,
      case when items.rows is null then 'Legacy bill' else 'Bill items' end as item_source,
      coalesce(spins.rows,'[]'::jsonb) as spins
    from page s join public.campaigns c on c.id=s.campaign_id
    cross join parameters p
    left join lateral (
      select jsonb_agg(jsonb_build_object('product_id',si.product_id,'sku_code',si.sku_code,
        'product_name',si.product_name,'quantity',si.quantity) order by si.sku_code,si.product_id) as rows
      from public.sale_items si where si.sale_id=s.id
    ) items on true
    left join lateral (
      select jsonb_agg(jsonb_build_object(
        'id',sp.id,'spin_id',sp.spin_code,'spin_no',sp.spin_no,'spun_at',sp.created_at,
        'spin_date',(sp.created_at at time zone 'Asia/Kolkata')::date,
        'spin_time',to_char(sp.created_at at time zone 'Asia/Kolkata','HH24:MI:SS'),
        'prize_name',sp.prize_name,'prize_code',sp.prize_code,'prize_cost',sp.prize_cost,
        'substituted',sp.substituted,'redemption_status',sp.redemption_status,
        'inventory_status',sp.inventory_status,'handed_over_at',sp.handed_over_at,
        'handover_date',(sp.handed_over_at at time zone 'Asia/Kolkata')::date,
        'handover_time',to_char(sp.handed_over_at at time zone 'Asia/Kolkata','HH24:MI:SS'),
        'config_version',sp.config_version,
        'distribution_version',to_jsonb(sp)->'distribution_version',
        'distribution_mode',to_jsonb(sp)->>'distribution_mode',
        'device_ref',coalesce(sp.device_ref,s.device_ref)
      ) order by sp.created_at,sp.id) as rows
      from public.spins sp where sp.sale_id=s.id and sp.created_at <= p.as_of
    ) spins on true
  )
  select jsonb_build_object(
    'as_of',(select as_of from parameters),'read_at',statement_timestamp(),
    'bills',coalesce((select jsonb_agg(to_jsonb(b) order by b.transaction_id) from bills b),'[]'::jsonb),
    'next_after',case when (select count(*) from selected) > (select page_size from parameters)
      then (select id from page order by id desc limit 1) else null end
  )
$report$;

revoke all on function public.transaction_report_page(jsonb,uuid,timestamptz,integer) from public,anon,authenticated;
grant execute on function public.transaction_report_page(jsonb,uuid,timestamptz,integer) to authenticated;
comment on function public.transaction_report_page(jsonb,uuid,timestamptz,integer) is
  'Read-only Transactions-tab bill, spin and SKU source. Caller RLS applies. Date/SKU filters select bills; SKU lines are filtered separately by the screen. New bills/spins after as_of are excluded; statuses are current at each page read.';
commit;
notify pgrst, 'reload schema';
