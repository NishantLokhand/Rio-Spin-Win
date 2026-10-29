-- Emergency recovery: restores the exact working pre-V8 entry routes.
-- Existing speaker wins, stock movements, and daily-award records are retained.
begin;
set local lock_timeout='5s';
update public.prize_v8_settings s set enabled=false,updated_at=now()
where s.campaign_id in (select id from public.campaigns where code='RSW-2026');

create or replace function public._draw_cumulative_prize(
  p_campaign public.campaigns,p_config public.prize_configs,p_promoter uuid,p_key text
)
returns table(prize_id uuid,unit_cost numeric,total_spins integer)
language plpgsql security definer set search_path=public,extensions as $dispatch$
declare v_mode text;
begin
  -- RIO_V7_DISPATCH_20261029
  if p_campaign.code='RSW-2026' then v_mode:=public._v7_distribution_mode(p_promoter); end if;
  if v_mode is not null then
    perform set_config('rio.distribution_version','7',true);
    return query select v.* from public._draw_prize_v7_20261029(p_campaign,p_config,p_promoter,v_mode) v;
  else
    perform set_config('rio.distribution_version','6',true);
    perform set_config('rio.distribution_mode','v6',true);
    return query select v.* from public._draw_cumulative_prize_v6_20261029(p_campaign,p_config,p_promoter,p_key) v;
  end if;
end $dispatch$;
revoke all on function public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;


CREATE OR REPLACE FUNCTION public._stock_problem(c campaigns, p_config prize_configs, p_promoter uuid, p_key text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

revoke all on function public._stock_problem(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
