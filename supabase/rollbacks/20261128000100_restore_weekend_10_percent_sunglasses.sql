-- Restore the previous Thane/Mumbai weekend allocation percentages.
-- Existing allocation counters are retained; no completed spins or stock records change.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $preflight$
declare v_campaign uuid;
begin
  if to_regclass('public.prize_weekend_market_settings') is null then
    raise exception 'Thane/Mumbai weekend rule is not installed; no changes committed';
  end if;
  select id into v_campaign from public.campaigns where code='RSW-2026';
  if v_campaign is null then raise exception 'RSW-2026 campaign not found; no changes committed'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rio_weekend_market:'||v_campaign::text,0));
end $preflight$;

create or replace function public._draw_prize_weekend_market_20261127(
  p_campaign public.campaigns,p_config public.prize_configs,p_promoter uuid,p_key text
)
returns table(prize_id uuid,unit_cost numeric,total_spins integer)
language plpgsql security definer set search_path=public,extensions as $draw$
declare
  v_five uuid; v_ten uuid; v_shades uuid;
  v_five_cost numeric; v_ten_cost numeric; v_shades_cost numeric;
  v_has_shades boolean; v_alloc public.prize_weekend_market_allocations;
  v_n integer; v_best numeric; v_total_weight numeric; v_random numeric; v_acc numeric;
  v_item record; v_won uuid; v_cost numeric; v_attempt integer;
begin
  if p_campaign.code<>'RSW-2026' then
    return query select d.* from public._draw_prize_pre_v8_20261029(p_campaign,p_config,p_promoter,p_key) d;
    return;
  end if;
  -- Serialize activation/rollback against a draw, then recheck the switch.
  perform pg_advisory_xact_lock(hashtextextended('rio_weekend_market:'||p_campaign.id::text,0));
  if not public._weekend_market_rule_active(p_promoter) then
    return query select d.* from public._draw_prize_pre_v8_20261029(p_campaign,p_config,p_promoter,p_key) d;
    return;
  end if;
  select p.id,coalesce(i.unit_cost,p.default_cost) into v_five,v_five_cost
  from public.prizes p left join public.prize_config_items i on i.prize_id=p.id and i.config_id=p_config.id
  where p.code='SNACK5' and p.is_active;
  select p.id,coalesce(i.unit_cost,p.default_cost) into v_ten,v_ten_cost
  from public.prizes p left join public.prize_config_items i on i.prize_id=p.id and i.config_id=p_config.id
  where p.code='SNACK10' and p.is_active;
  select p.id,coalesce(i.unit_cost,p.default_cost) into v_shades,v_shades_cost
  from public.prizes p left join public.prize_config_items i on i.prize_id=p.id and i.config_id=p_config.id
  where p.code='SHADES' and p.is_active;
  if v_five is null or v_ten is null or v_shades is null then raise exception 'NO_PRIZE_CONFIG'; end if;

  -- One combined Thane + Mumbai cohort, separated only by sunglasses stock.
  for v_attempt in 1..10 loop
    v_has_shades := not p_campaign.track_inventory or public._available(p_promoter,v_shades)>0;
    insert into public.prize_weekend_market_allocations(campaign_id,shades_available)
      values(p_campaign.id,v_has_shades) on conflict(campaign_id,shades_available) do nothing;
    select a.* into strict v_alloc from public.prize_weekend_market_allocations a
      where a.campaign_id=p_campaign.id and a.shades_available=v_has_shades for update;
    v_n:=v_alloc.total_spins+1;

    -- With sunglasses stock: 66% ₹5 / 24% ₹10 / 10% sunglasses.
    -- Without it: preserve the current 75% / 25% snack fallback.
    select max(q.deficit) into v_best
    from (
      select x.prize_id,x.pct,(v_n::numeric*x.pct/100.0)-x.actual as deficit
      from (values
        (v_five,case when v_has_shades then 66::numeric else 75::numeric end,v_alloc.snack5_awarded),
        (v_ten,case when v_has_shades then 24::numeric else 25::numeric end,v_alloc.snack10_awarded),
        (v_shades,case when v_has_shades then 10::numeric else 0::numeric end,v_alloc.shades_awarded)
      ) as x(prize_id,pct,actual)
      where x.pct>0 and (not p_campaign.track_inventory or public._available(p_promoter,x.prize_id)>0)
    ) q;
    if v_best is null then raise exception 'OUT_OF_STOCK' using hint='No weekend-rule prize is currently in stock.'; end if;

    select sum(q.weight) into v_total_weight from (
      select x.pct*exp(greatest(-4.0,least(0.0,(x.deficit-v_best)/0.75))) as weight
      from (
        select y.pct,(v_n::numeric*y.pct/100.0)-y.actual as deficit
        from (values
          (v_five,case when v_has_shades then 66::numeric else 75::numeric end,v_alloc.snack5_awarded),
          (v_ten,case when v_has_shades then 24::numeric else 25::numeric end,v_alloc.snack10_awarded),
          (v_shades,case when v_has_shades then 10::numeric else 0::numeric end,v_alloc.shades_awarded)
        ) as y(prize_id,pct,actual)
        where y.pct>0 and (not p_campaign.track_inventory or public._available(p_promoter,y.prize_id)>0)
      ) x
    ) q;
    if coalesce(v_total_weight,0)<=0 then raise exception 'OUT_OF_STOCK'; end if;
    v_random:=((('x'||encode(extensions.gen_random_bytes(6),'hex'))::bit(48)::bigint)::numeric/281474976710656)*v_total_weight;
    v_acc:=0; v_won:=null; v_cost:=null;
    for v_item in
      select x.prize_id,x.pct*exp(greatest(-4.0,least(0.0,(x.deficit-v_best)/0.75))) as weight,
        case x.prize_id when v_five then v_five_cost when v_ten then v_ten_cost else v_shades_cost end as cost
      from (
        select y.prize_id,y.pct,(v_n::numeric*y.pct/100.0)-y.actual as deficit
        from (values
          (v_five,case when v_has_shades then 66::numeric else 75::numeric end,v_alloc.snack5_awarded),
          (v_ten,case when v_has_shades then 24::numeric else 25::numeric end,v_alloc.snack10_awarded),
          (v_shades,case when v_has_shades then 10::numeric else 0::numeric end,v_alloc.shades_awarded)
        ) as y(prize_id,pct,actual)
        where y.pct>0 and (not p_campaign.track_inventory or public._available(p_promoter,y.prize_id)>0)
      ) x order by x.prize_id
    loop
      v_acc:=v_acc+v_item.weight;
      if v_random<v_acc then v_won:=v_item.prize_id; v_cost:=v_item.cost; exit; end if;
    end loop;
    if v_won is null then
      select x.prize_id,case x.prize_id when v_five then v_five_cost when v_ten then v_ten_cost else v_shades_cost end
        into v_won,v_cost
      from (
        select y.prize_id,y.pct*exp(greatest(-4.0,least(0.0,(y.deficit-v_best)/0.75))) as weight
        from (
          select z.prize_id,z.pct,(v_n::numeric*z.pct/100.0)-z.actual as deficit
          from (values
            (v_five,case when v_has_shades then 66::numeric else 75::numeric end,v_alloc.snack5_awarded),
            (v_ten,case when v_has_shades then 24::numeric else 25::numeric end,v_alloc.snack10_awarded),
            (v_shades,case when v_has_shades then 10::numeric else 0::numeric end,v_alloc.shades_awarded)
          ) as z(prize_id,pct,actual)
          where z.pct>0 and (not p_campaign.track_inventory or public._available(p_promoter,z.prize_id)>0)
        ) y
      ) x order by x.weight desc,x.prize_id limit 1;
    end if;

    if p_campaign.track_inventory then
      update public.promoter_inventory inv set reserved=inv.reserved+1,updated_at=now()
      where inv.promoter_id=p_promoter and inv.prize_id=v_won and inv.on_hand-inv.reserved>0;
      if not found then continue; end if;
    end if;
    update public.prize_weekend_market_allocations a
    set total_spins=v_n,
        snack5_awarded=a.snack5_awarded+case when v_won=v_five then 1 else 0 end,
        snack10_awarded=a.snack10_awarded+case when v_won=v_ten then 1 else 0 end,
        shades_awarded=a.shades_awarded+case when v_won=v_shades then 1 else 0 end,
        updated_at=now()
    where a.campaign_id=p_campaign.id and a.shades_available=v_has_shades;
    perform set_config('rio.distribution_version','9',true);
    perform set_config('rio.distribution_mode',case when v_has_shades then 'weekend_thane_mumbai_shades' else 'weekend_thane_mumbai_no_shades' end,true);
    perform set_config('rio.shade_eligible_draw',case when v_has_shades then 'true' else 'false' end,true);
    prize_id:=v_won; unit_cost:=v_cost; total_spins:=v_n; return next; return;
  end loop;
  raise exception 'OUT_OF_STOCK' using hint='Prize stock changed during the draw. Please retry.';
end $draw$;
revoke all on function public._draw_prize_weekend_market_20261127(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;

create or replace function public.get_prize_weekend_market_status(p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $status$
declare r jsonb;
begin
  perform public._require_staff();
  select jsonb_build_object(
    'enabled',s.enabled,'effective',s.enabled and s.starts_at is not null and now()>=s.starts_at and now()<s.ends_at,
    'starts_at',s.starts_at,'ends_at',s.ends_at,'speaker_spin_number',8,
    'markets',jsonb_build_array('THANE','MUMBAI'),
    'market_users',(select count(distinct u.id) from public.app_users u join public.org_people op on op.auth_user_id=u.id
      where u.role='promoter' and u.is_active and regexp_replace(upper(coalesce(nullif(btrim(op.market_override),''),op.market_raw,'')),'[^A-Z0-9]','','g') in ('THANE','MUMBAI')),
    'v8_selected_market_users',(select count(distinct u.id) from public.app_users u join public.org_people op on op.auth_user_id=u.id
      join public.prize_v8_users v on v.user_id=u.id and v.enabled
      where u.role='promoter' and u.is_active and regexp_replace(upper(coalesce(nullif(btrim(op.market_override),''),op.market_raw,'')),'[^A-Z0-9]','','g') in ('THANE','MUMBAI')),
    'speakers_awarded_today',(select count(*) from public.prize_v8_daily_awards a join public.org_people op on op.auth_user_id=a.user_id
      where a.campaign_id=p_campaign and a.biz_date=public.ist_today()
      and regexp_replace(upper(coalesce(nullif(btrim(op.market_override),''),op.market_raw,'')),'[^A-Z0-9]','','g') in ('THANE','MUMBAI')),
    'sunglasses_rule','10% sunglasses / 66% ₹5 snacks / 24% ₹10 snacks when sunglasses stock is available; no-stock fallback 75% / 25%',
    'speaker_rule','Existing Version 8 selected users only: one speaker on daily spin 8 when in stock; no catch-up later that day'
  ) into r from public.prize_weekend_market_settings s where s.campaign_id=p_campaign;
  return r;
end $status$;

notify pgrst,'reload schema';
commit;
