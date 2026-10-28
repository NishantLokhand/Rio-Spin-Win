-- Fix the allocation upsert rejected by Supabase safe-update protection.
+create or replace function public._get_or_create_allocation(
    p_campaign uuid, p_scope public.pool_scope, p_key text)
returns public.campaign_allocations language plpgsql security definer set search_path = public as $$
declare
  v_alloc public.campaign_allocations;
  v_spins int := 0;
  v_awarded jsonb := '{}'::jsonb;
begin
  select * into v_alloc from public.campaign_allocations
   where campaign_id = p_campaign and scope = p_scope and scope_key = p_key
   for update;

  if v_alloc.id is null then
    -- Initialize from existing completed spins for this scope so historical data continues seamlessly
    select coalesce(sum(cnt), 0), coalesce(jsonb_object_agg(prize_id::text, cnt), '{}'::jsonb)
      into v_spins, v_awarded
      from (
        select sp.prize_id, count(*) as cnt
          from public.spins sp
          join public.sales sa on sa.id = sp.sale_id
         where sp.campaign_id = p_campaign
           and (
             (p_scope = 'promoter'  and sp.promoter_id::text = p_key) or
             (p_scope = 'outlet'    and sa.outlet_id::text = p_key) or
             (p_scope = 'territory' and sa.territory_id::text = p_key) or
             (p_scope = 'state'     and sa.state_id::text = p_key) or
             (p_scope = 'campaign'  and sp.campaign_id::text = p_key)
           )
           and sp.redemption_status <> 'not_redeemed'
         group by sp.prize_id
      ) q;

    insert into public.campaign_allocations (campaign_id, scope, scope_key, total_spins, awarded)
    values (p_campaign, p_scope, p_key, coalesce(v_spins, 0), coalesce(v_awarded, '{}'::jsonb))
    on conflict (campaign_id, scope, scope_key) do update
       set updated_at = now()
     where public.campaign_allocations.campaign_id = excluded.campaign_id
       and public.campaign_allocations.scope = excluded.scope
       and public.campaign_allocations.scope_key = excluded.scope_key
    returning * into v_alloc;
  end if;

  return v_alloc;
end $$;



notify pgrst, 'reload schema';
