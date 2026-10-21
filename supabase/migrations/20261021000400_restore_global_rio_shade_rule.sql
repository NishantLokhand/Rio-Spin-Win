-- Corrective migration: restore the intended global, inventory-gated rule.
-- Users with Rio Shade stock can receive the 5% Rio Shade slots.
-- Users without Rio Shade stock skip those slots and remain effectively 85/15 snacks.
do $$
declare
  base_campaign record;
  old_cfg record;
  shade_id uuid;
  snack5_id uuid;
  snack10_id uuid;
  admin_id uuid;
  new_cfg uuid;
  v_version int;
  pool_size int := 200;
  q5 int := 160;
  q10 int := 30;
  qs int := 10;
  total_cost numeric;
begin
  select * into base_campaign from public.campaigns where code='RSW-2026' limit 1;
  if base_campaign.id is null then raise exception 'Base campaign RSW-2026 was not found'; end if;
  select id into admin_id from public.app_users where role='admin' order by created_at limit 1;
  select id into snack5_id from public.prizes where code='SNACK5';
  select id into snack10_id from public.prizes where code='SNACK10';
  select id into shade_id from public.prizes where code='SHADES';
  if shade_id is null then
    insert into public.prizes(code,name,short_name,tier,default_cost,wheel_label,win_title,win_subtitle,low_stock_threshold,is_active,sort_order)
    values ('SHADES','Rio Sunglasses','Rio Shades','high',100,'RIO SUNGLASSES','😎 YOU WON RIO SHADES!','LOOKING COOL!',1,true,4)
    returning id into shade_id;
  else
    update public.prizes set is_active=true,name='Rio Sunglasses',short_name='Rio Shades',wheel_label='RIO SUNGLASSES',win_title='😎 YOU WON RIO SHADES!',win_subtitle='LOOKING COOL!' where id=shade_id;
  end if;
  total_cost := q5*(select default_cost from public.prizes where id=snack5_id)+q10*(select default_cost from public.prizes where id=snack10_id)+qs*(select default_cost from public.prizes where id=shade_id);

  -- Close the temporary selected-user campaign created by the previous migration.
  update public.campaigns set status='closed',updated_at=now() where code='RSW-2026-SHADE-DEMO' and status <> 'closed';
  delete from public.campaign_promoters where campaign_id=(select id from public.campaigns where code='RSW-2026-SHADE-DEMO');

  -- Make the original campaign's new configuration global for every user.
  update public.prize_configs set is_active=false where campaign_id=base_campaign.id and is_active;
  select coalesce(max(version),0)+1 into v_version from public.prize_configs where campaign_id=base_campaign.id;
  insert into public.prize_configs(campaign_id,state_id,version,pool_size,total_cost,avg_cost,target_cost,exceeds_target,override_by,is_active,notes,created_by)
  values(base_campaign.id,null,v_version,pool_size,total_cost,total_cost/pool_size,base_campaign.target_cost_per_spin,total_cost/pool_size > base_campaign.target_cost_per_spin,admin_id,true,'Global inventory-gated rule: 80% ₹5, 15% ₹10, 5% Rio Shades',admin_id)
  returning id into new_cfg;
  insert into public.prize_config_items(config_id,prize_id,quantity,unit_cost,percentage)
  values(new_cfg,snack5_id,q5,(select default_cost from public.prizes where id=snack5_id),80),(new_cfg,snack10_id,q10,(select default_cost from public.prizes where id=snack10_id),15),(new_cfg,shade_id,qs,(select default_cost from public.prizes where id=shade_id),5);
  update public.campaigns set config_change_mode='regenerate_now',updated_at=now() where id=base_campaign.id;

  -- Issue 20 shades to the current demo test users only. Existing shade stock is preserved.
  if admin_id is not null then
    insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved,updated_at)
    select u.id,shade_id,20,0,now() from public.app_users u where u.role='promoter' and u.login_id in ('demo01','demo02','demo03','demo04')
    on conflict (promoter_id,prize_id) do update set on_hand=greatest(public.promoter_inventory.on_hand,20),updated_at=now();
    insert into public.inventory_movements(promoter_id,prize_id,movement_type,qty,on_hand_after,performed_by,reference,note)
    select u.id,shade_id,'issue',20,20,admin_id,'Selected-user Rio Shade setup','20 Rio Shades issued by corrective migration'
    from public.app_users u where u.role='promoter' and u.login_id in ('demo01','demo02','demo03','demo04')
      and not exists (select 1 from public.inventory_movements m where m.promoter_id=u.id and m.prize_id=shade_id and m.reference='Selected-user Rio Shade setup');
  end if;

  -- Temporary test exception: include only demo01-demo04 in reports.
  delete from public.reporting_excluded_users e using public.app_users u where u.id=e.user_id and u.login_id in ('demo01','demo02','demo03','demo04');
  create or replace function public._report_excluded_user_ids() returns uuid[] language sql stable security definer set search_path=public as $fn$
    select coalesce(array_agg(distinct a.id),'{}'::uuid[]) from public.app_users a
    where a.login_id not in ('demo01','demo02','demo03','demo04')
      and (exists(select 1 from public.reporting_excluded_users e where e.user_id=a.id)
        or (a.role='promoter' and (a.full_name ~* '(^|[^[:alnum:]])(test|demo)([^[:alnum:]]|$)' or a.login_id ~* '^(test|demo)([^[:alpha:]]|$)')))
  $fn$;
  revoke all on function public._report_excluded_user_ids() from public,anon,authenticated;
  notify pgrst,'reload schema';
end $$;
