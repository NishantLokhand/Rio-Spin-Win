-- Selected-user Rio Shade campaign. Existing 85/15 campaign is unchanged.
do $$
declare
  base_campaign record; shade_campaign uuid; cfg uuid; shade_id uuid; snack5_id uuid; snack10_id uuid; admin_id uuid;
  state_row record; product_row record; pool_size int := 200; q5 int := 160; q10 int := 30; qs int := 10; total_cost numeric := 0;
begin
  select * into base_campaign from public.campaigns where code='RSW-2026' limit 1;
  if base_campaign.id is null then raise exception 'Base campaign RSW-2026 was not found'; end if;
  select id into admin_id from public.app_users where role='admin' order by created_at limit 1;
  select id into snack5_id from public.prizes where code='SNACK5';
  select id into snack10_id from public.prizes where code='SNACK10';
  select id into shade_id from public.prizes where code='SHADES';
  if shade_id is null then
    insert into public.prizes(code,name,short_name,tier,default_cost,wheel_label,win_title,win_subtitle,low_stock_threshold,is_active,sort_order)
    values ('SHADES','Rio Sunglasses','Rio Shades','high',100,'RIO SUNGLASSES','😎 YOU WON RIO SHADES!','LOOKING COOL!',1,true,4) returning id into shade_id;
  else
    update public.prizes set is_active=true,name='Rio Sunglasses',short_name='Rio Shades',wheel_label='RIO SUNGLASSES',win_title='😎 YOU WON RIO SHADES!',win_subtitle='LOOKING COOL!' where id=shade_id;
  end if;
  total_cost := q5*(select default_cost from public.prizes where id=snack5_id)+q10*(select default_cost from public.prizes where id=snack10_id)+qs*(select default_cost from public.prizes where id=shade_id);
  select id into shade_campaign from public.campaigns where code='RSW-2026-SHADE-DEMO';
  if shade_campaign is null then
    insert into public.campaigns(code,name,status,start_date,end_date,target_cost_per_spin,total_budget,daily_budget,enforce_budget,pool_scope,draw_strategy,oos_mode,config_change_mode,track_inventory,spins_per_sale,max_quantity_per_sale,validation_rules,capture_consumer,sound_default,work_start,work_end,flag_rules)
    values ('RSW-2026-SHADE-DEMO','RIO SPIN & WIN — Selected Rio Shade users','active',base_campaign.start_date,base_campaign.end_date,base_campaign.target_cost_per_spin,base_campaign.total_budget,base_campaign.daily_budget,base_campaign.enforce_budget,base_campaign.pool_scope,base_campaign.draw_strategy,base_campaign.oos_mode,'regenerate_now',base_campaign.track_inventory,base_campaign.spins_per_sale,base_campaign.max_quantity_per_sale,base_campaign.validation_rules,base_campaign.capture_consumer,base_campaign.sound_default,base_campaign.work_start,base_campaign.work_end,base_campaign.flag_rules) returning id into shade_campaign;
    for state_row in select state_id,budget from public.campaign_states where campaign_id=base_campaign.id loop insert into public.campaign_states(campaign_id,state_id,budget) values(shade_campaign,state_row.state_id,state_row.budget); end loop;
    for product_row in select product_id,sort_order from public.campaign_products where campaign_id=base_campaign.id loop insert into public.campaign_products(campaign_id,product_id,sort_order) values(shade_campaign,product_row.product_id,product_row.sort_order); end loop;
  end if;
  select id into cfg from public.prize_configs where campaign_id=shade_campaign and is_active limit 1;
  if cfg is null then
    insert into public.prize_configs(campaign_id,state_id,version,pool_size,total_cost,avg_cost,target_cost,exceeds_target,override_by,is_active,notes,created_by)
    values(shade_campaign,null,1,pool_size,total_cost,total_cost/pool_size,base_campaign.target_cost_per_spin,total_cost/pool_size > base_campaign.target_cost_per_spin,admin_id,true,'Selected users: 80% ₹5, 15% ₹10, 5% Rio Shades',admin_id) returning id into cfg;
    insert into public.prize_config_items(config_id,prize_id,quantity,unit_cost,percentage)
    values(cfg,snack5_id,q5,(select default_cost from public.prizes where id=snack5_id),80),(cfg,snack10_id,q10,(select default_cost from public.prizes where id=snack10_id),15),(cfg,shade_id,qs,(select default_cost from public.prizes where id=shade_id),5);
  end if;
  delete from public.campaign_promoters where campaign_id=shade_campaign;
  insert into public.campaign_promoters(campaign_id,promoter_id) select shade_campaign,id from public.app_users where role='promoter' and login_id in ('demo01','demo02','demo03','demo04') on conflict do nothing;
  if admin_id is not null then
    insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved,updated_at) select u.id,shade_id,20,0,now() from public.app_users u where u.role='promoter' and u.login_id in ('demo01','demo02','demo03','demo04') on conflict (promoter_id,prize_id) do update set on_hand=greatest(public.promoter_inventory.on_hand,20),updated_at=now();
    insert into public.inventory_movements(promoter_id,prize_id,movement_type,qty,on_hand_after,performed_by,reference,note) select u.id,shade_id,'issue',20,20,admin_id,'Selected-user Rio Shade setup','20 Rio Shades issued by migration' from public.app_users u where u.role='promoter' and u.login_id in ('demo01','demo02','demo03','demo04') and not exists (select 1 from public.inventory_movements m where m.promoter_id=u.id and m.prize_id=shade_id and m.reference='Selected-user Rio Shade setup');
  end if;
  -- Temporary test exception: show only demo01-demo04 in reports.
  delete from public.reporting_excluded_users e using public.app_users u where u.id=e.user_id and u.login_id in ('demo01','demo02','demo03','demo04');
  create or replace function public._report_excluded_user_ids() returns uuid[] language sql stable security definer set search_path=public as $fn$
    select coalesce(array_agg(distinct a.id),'{}'::uuid[]) from public.app_users a where a.login_id not in ('demo01','demo02','demo03','demo04') and (exists(select 1 from public.reporting_excluded_users e where e.user_id=a.id) or (a.role='promoter' and (a.full_name ~* '(^|[^[:alnum:]])(test|demo)([^[:alnum:]]|$)' or a.login_id ~* '^(test|demo)([^[:alpha:]]|$)')))
  $fn$;
  revoke all on function public._report_excluded_user_ids() from public,anon,authenticated;
  notify pgrst,'reload schema';
end $$;
