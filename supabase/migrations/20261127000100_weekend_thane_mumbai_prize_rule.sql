-- Temporary Thane/Mumbai prize rule for the 27–29 Nov 2026 weekend.
-- Enable it from Prize Structure after applying this migration. The start time
-- is recorded at activation; the rule expires automatically at Monday 00:00 IST.
-- Ordinary prize mix applies to all users in the two markets. The existing V8
-- selected-user list gets its one daily speaker opportunity on spin 8 instead
-- of spin 10 while the temporary rule is effective.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $preflight$
declare v_campaign uuid; v_end timestamptz;
begin
  if to_regprocedure('public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text)') is null
     or to_regprocedure('public._draw_prize_v8_20261029(public.campaigns,public.prize_configs,uuid,text)') is null
     or to_regprocedure('public._draw_prize_pre_v8_20261029(public.campaigns,public.prize_configs,uuid,text)') is null
     or to_regprocedure('public._v8_speaker_due(uuid,uuid)') is null
     or to_regprocedure('public._stock_problem(public.campaigns,public.prize_configs,uuid,text)') is null
     or to_regprocedure('public.report_v8_speaker_users(date)') is null
     or to_regclass('public.prize_v8_settings') is null
     or to_regclass('public.prize_v8_users') is null
     or to_regclass('public.prize_v8_daily_awards') is null then
    raise exception 'Expected working V8 installation is missing; no changes committed';
  end if;
  if to_regclass('public.org_people') is null or to_regclass('public.promoter_inventory') is null
     or to_regclass('public.prizes') is null or to_regclass('public.prize_config_items') is null
     or to_regclass('public.spins') is null then
    raise exception 'Required profile, inventory, prize or spin tables are missing; no changes committed';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='org_people' and column_name='auth_user_id')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='org_people' and column_name='market_override')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='promoter_inventory' and column_name='on_hand')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='promoter_inventory' and column_name='reserved') then
    raise exception 'Required profile or inventory columns are missing; no changes committed';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid=to_regprocedure('public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text)')
      and position('RIO_V8_DISPATCH_20261029' in p.prosrc)>0
  ) then raise exception 'Current V8 dispatcher marker is missing; no changes committed'; end if;
  select id into v_campaign from public.campaigns where code='RSW-2026' and track_inventory and snack_launch_active is not true;
  if v_campaign is null then raise exception 'Expected inventory-tracked RSW-2026 campaign with launch phase off'; end if;
  if not exists (select 1 from public.prizes where code='SNACK5' and is_active)
     or not exists (select 1 from public.prizes where code='SNACK10' and is_active)
     or not exists (select 1 from public.prizes where code='SHADES' and is_active)
     or not exists (select 1 from public.prizes where code='SPEAKER' and is_active) then
    raise exception 'Active ₹5, ₹10, sunglasses and speaker catalogue entries are required';
  end if;
  v_end := make_timestamptz(2026,11,30,0,0,0,'Asia/Kolkata');
  if clock_timestamp() >= v_end then raise exception 'The 27–29 Nov weekend activation window has ended'; end if;
end $preflight$;

create table if not exists public.prize_weekend_market_settings (
  campaign_id uuid primary key references public.campaigns(id),
  enabled boolean not null default false,
  starts_at timestamptz,
  ends_at timestamptz not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.app_users(id),
  check (starts_at is null or starts_at < ends_at)
);
create table if not exists public.prize_weekend_market_allocations (
  campaign_id uuid not null references public.campaigns(id),
  shades_available boolean not null,
  total_spins integer not null default 0 check(total_spins>=0),
  snack5_awarded integer not null default 0 check(snack5_awarded>=0),
  snack10_awarded integer not null default 0 check(snack10_awarded>=0),
  shades_awarded integer not null default 0 check(shades_awarded>=0),
  updated_at timestamptz not null default now(),
  primary key(campaign_id,shades_available),
  check(total_spins=snack5_awarded+snack10_awarded+shades_awarded)
);
alter table public.prize_weekend_market_settings enable row level security;
alter table public.prize_weekend_market_allocations enable row level security;
revoke all on public.prize_weekend_market_settings,public.prize_weekend_market_allocations from public,anon,authenticated;

insert into public.prize_weekend_market_settings(campaign_id,enabled,starts_at,ends_at)
select c.id,false,null,make_timestamptz(2026,11,30,0,0,0,'Asia/Kolkata')
from public.campaigns c where c.code='RSW-2026'
on conflict(campaign_id) do nothing;

create or replace function public._weekend_market_rule_active(p_user uuid)
returns boolean language sql volatile security definer set search_path=public as $active$
  select exists(
    select 1
    from public.prize_weekend_market_settings s
    join public.campaigns c on c.id=s.campaign_id and c.code='RSW-2026'
    join public.org_people op on op.auth_user_id=p_user
    where s.campaign_id=c.id and s.enabled and s.starts_at is not null
      and now()>=s.starts_at and now()<s.ends_at
      and regexp_replace(upper(coalesce(nullif(btrim(op.market_override),''),op.market_raw,'')),'[^A-Z0-9]','','g') in ('THANE','MUMBAI')
  )
$active$;
revoke all on function public._weekend_market_rule_active(uuid) from public,anon,authenticated;

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

create or replace function public._v8_speaker_due(p_campaign uuid,p_user uuid)
returns boolean language sql stable security definer set search_path=public as $due$
  select public._v8_user_enabled(p_campaign,p_user)
    and (select count(*) from public.spins sp
      where sp.promoter_id=p_user and sp.campaign_id=p_campaign and sp.biz_date=public.ist_today())=
        case when public._weekend_market_rule_active(p_user) then 7 else 9 end
    and not exists(select 1 from public.prize_v8_daily_awards a where a.user_id=p_user and a.biz_date=public.ist_today())
    and not exists(select 1 from public.spins sp join public.prizes p on p.id=sp.prize_id
      where sp.promoter_id=p_user and sp.biz_date=public.ist_today() and p.code='SPEAKER')
$due$;
revoke all on function public._v8_speaker_due(uuid,uuid) from public,anon,authenticated;

create or replace function public._stock_problem(c public.campaigns,p_config public.prize_configs,p_promoter uuid,p_key text)
returns text language plpgsql stable security definer set search_path=public as $stock$
begin
  if c.code='RSW-2026' and public._v8_speaker_due(c.id,p_promoter) and exists(
    select 1 from public.prizes p where p.code='SPEAKER' and p.is_active and public._available(p_promoter,p.id)>0
  ) then return null; end if;
  return public._stock_problem_pre_v8_20261029(c,p_config,p_promoter,p_key);
end $stock$;
revoke all on function public._stock_problem(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;

create or replace function public._draw_prize_v8_20261029(
  p_campaign public.campaigns,p_config public.prize_configs,p_promoter uuid,p_key text
)
returns table(prize_id uuid,unit_cost numeric,total_spins integer)
language plpgsql security definer set search_path=public,extensions as $draw$
declare v_speaker uuid; v_cost numeric; v_today date:=public.ist_today(); v_total integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('rio_v8:'||p_promoter::text||':'||v_today::text,0));
  -- Make the eighth-spin check mutually exclusive with the weekend rollback.
  if public._weekend_market_rule_active(p_promoter) then
    perform pg_advisory_xact_lock(hashtextextended('rio_weekend_market:'||p_campaign.id::text,0));
  end if;
  if public._v8_speaker_due(p_campaign.id,p_promoter) then
    select p.id,coalesce(i.unit_cost,p.default_cost) into v_speaker,v_cost
    from public.prizes p left join public.prize_config_items i on i.prize_id=p.id and i.config_id=p_config.id
    where p.code='SPEAKER' and p.is_active;
    if v_speaker is not null then
      update public.promoter_inventory inv set reserved=inv.reserved+1,updated_at=now()
      where inv.promoter_id=p_promoter and inv.prize_id=v_speaker and inv.on_hand-inv.reserved>0;
      if found then
        insert into public.prize_v8_daily_awards(user_id,biz_date,campaign_id,prize_id)
        values(p_promoter,v_today,p_campaign.id,v_speaker);
        perform set_config('rio.distribution_version','8',true);
        perform set_config('rio.distribution_mode',case when public._weekend_market_rule_active(p_promoter) then 'speaker_eighth_weekend' else 'speaker_tenth_daily' end,true);
        perform set_config('rio.shade_eligible_draw','na',true);
        select count(*)::integer+1 into v_total from public.spins sp
        where sp.promoter_id=p_promoter and sp.campaign_id=p_campaign.id and sp.biz_date=v_today;
        prize_id:=v_speaker; unit_cost:=v_cost; total_spins:=v_total; return next; return;
      end if;
    end if;
  end if;
  if public._weekend_market_rule_active(p_promoter) then
    return query select d.* from public._draw_prize_weekend_market_20261127(p_campaign,p_config,p_promoter,p_key) d;
  else
    return query select d.* from public._draw_prize_pre_v8_20261029(p_campaign,p_config,p_promoter,p_key) d;
  end if;
end $draw$;
revoke all on function public._draw_prize_v8_20261029(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;

create or replace function public._draw_cumulative_prize(
  p_campaign public.campaigns,p_config public.prize_configs,p_promoter uuid,p_key text
)
returns table(prize_id uuid,unit_cost numeric,total_spins integer)
language plpgsql security definer set search_path=public,extensions as $dispatch$
begin
  -- RIO_V8_DISPATCH_20261029 remains the single RPC-facing draw dispatcher.
  if public._v8_user_enabled(p_campaign.id,p_promoter) then
    return query select d.* from public._draw_prize_v8_20261029(p_campaign,p_config,p_promoter,p_key) d;
  elsif p_campaign.code='RSW-2026' and public._weekend_market_rule_active(p_promoter) then
    return query select d.* from public._draw_prize_weekend_market_20261127(p_campaign,p_config,p_promoter,p_key) d;
  else
    return query select d.* from public._draw_prize_pre_v8_20261029(p_campaign,p_config,p_promoter,p_key) d;
  end if;
end $dispatch$;
revoke all on function public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;

create or replace function public._stamp_spin_distribution_v7()
returns trigger language plpgsql security definer set search_path=public as $stamp$
begin
  if current_setting('rio.distribution_version',true) in ('6','7','8','9') then
    new.distribution_version:=current_setting('rio.distribution_version',true)::integer;
    new.distribution_mode:=nullif(current_setting('rio.distribution_mode',true),'');
  end if;
  return new;
end $stamp$;
revoke all on function public._stamp_spin_distribution_v7() from public,anon,authenticated;

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

create or replace function public.set_prize_weekend_market_enabled(p_campaign uuid,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path=public set lock_timeout='5s' as $toggle$
declare u public.app_users; s public.prize_weekend_market_settings; v_start timestamptz; v_thane integer; v_mumbai integer;
begin
  u:=public._require_staff();
  if u.role<>'admin' then raise exception 'ADMIN_ONLY'; end if;
  if p_enabled is null then raise exception 'Enabled must be true or false'; end if;
  if not exists(select 1 from public.campaigns where id=p_campaign and code='RSW-2026') then
    raise exception 'WEEKEND_RULE_NOT_INSTALLED';
  end if;
  -- Match the draw path's lock so a rollback waits for in-flight weekend draws.
  perform pg_advisory_xact_lock(hashtextextended('rio_weekend_market:'||p_campaign::text,0));
  select * into s from public.prize_weekend_market_settings where campaign_id=p_campaign for update;
  if s.campaign_id is null then raise exception 'WEEKEND_RULE_NOT_INSTALLED'; end if;
  if p_enabled then
    if clock_timestamp()>=s.ends_at then raise exception 'WEEKEND_WINDOW_CLOSED'; end if;
    if s.enabled and s.starts_at is not null and now()>=s.starts_at and now()<s.ends_at then
      return public.get_prize_weekend_market_status(p_campaign);
    end if;
    select count(distinct u0.id) filter(where regexp_replace(upper(coalesce(nullif(btrim(op.market_override),''),op.market_raw,'')),'[^A-Z0-9]','','g')='THANE'),
           count(distinct u0.id) filter(where regexp_replace(upper(coalesce(nullif(btrim(op.market_override),''),op.market_raw,'')),'[^A-Z0-9]','','g')='MUMBAI')
      into v_thane,v_mumbai
    from public.app_users u0 join public.org_people op on op.auth_user_id=u0.id
    where u0.role='promoter' and u0.is_active;
    if coalesce(v_thane,0)=0 or coalesce(v_mumbai,0)=0 then
      raise exception 'WEEKEND_MARKETS_NOT_FOUND' using detail=format('Active market user counts: Thane=%s, Mumbai=%s',coalesce(v_thane,0),coalesce(v_mumbai,0));
    end if;
    v_start:=clock_timestamp();
    update public.prize_weekend_market_settings set enabled=true,starts_at=v_start,updated_at=v_start,updated_by=u.id where campaign_id=p_campaign;
  else
    update public.prize_weekend_market_settings set enabled=false,updated_at=clock_timestamp(),updated_by=u.id where campaign_id=p_campaign;
  end if;
  perform public.write_audit('WEEKEND_MARKET_PRIZES_TOGGLED','campaigns',p_campaign::text,
    jsonb_build_object('enabled',p_enabled,'starts_at',case when p_enabled then v_start else s.starts_at end,'ends_at',s.ends_at,'markets',array['THANE','MUMBAI']));
  return public.get_prize_weekend_market_status(p_campaign);
end $toggle$;
revoke all on function public.get_prize_weekend_market_status(uuid),public.set_prize_weekend_market_enabled(uuid,boolean) from public,anon,authenticated;
grant execute on function public.get_prize_weekend_market_status(uuid),public.set_prize_weekend_market_enabled(uuid,boolean) to authenticated;

-- Keep the existing V8 status RPC accurate when the temporary eighth-spin
-- schedule is effective for the relevant market; all other users remain at 10.
create or replace function public.get_prize_v8_status(p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $status$
declare r jsonb;
begin
  perform public._require_staff();
  select jsonb_build_object('speaker_spin_number',10,'enabled',s.enabled,'starts_on',s.starts_on,'expires_on',s.expires_on,
    'effective',s.enabled and public.ist_today()>=s.starts_on and (s.expires_on is null or public.ist_today()<=s.expires_on),
    'selected_users',(select count(*) from public.prize_v8_users where enabled),
    'speakers_awarded_today',(select count(*) from public.prize_v8_daily_awards a where a.campaign_id=p_campaign and a.biz_date=public.ist_today()))
  into r from public.prize_v8_settings s where s.campaign_id=p_campaign;
  return r;
end $status$;

create or replace function public.report_v8_speaker_users(p_date date default public.ist_today())
returns jsonb language plpgsql stable security definer set search_path=public as $report$
declare r jsonb;
begin
  perform public._require_staff();
  select coalesce(jsonb_agg(to_jsonb(q) order by q.full_name),'[]'::jsonb) into r from (
    select v.user_id,u.full_name,p_date as date,v.reported_speakers,
      coalesce((select op.state_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as state,
      coalesce((select coalesce(nullif(btrim(op.market_override),''),op.market_raw) from public.org_people op where op.auth_user_id=u.id limit 1),'') as city,
      coalesce((select op.area_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as area,
      coalesce((select pi.on_hand-pi.reserved from public.promoter_inventory pi join public.prizes p on p.id=pi.prize_id where pi.promoter_id=u.id and p.code='SPEAKER'),0) as speakers_remaining,
      sp.spins as spins_today,
      case when p_date=public.ist_today() and public._weekend_market_rule_active(u.id) and public._v8_user_enabled(c.id,u.id) then 8 else 10 end as speaker_spin_number,
      case when a.spin_id is not null then 'Speaker awarded'
        when p_date=public.ist_today() and public._weekend_market_rule_active(u.id) and public._v8_user_enabled(c.id,u.id) and sp.spins>=8 then 'Eighth spin passed / no V8 speaker'
        when p_date=public.ist_today() and public._weekend_market_rule_active(u.id) and public._v8_user_enabled(c.id,u.id) then 'Waiting for eighth spin'
        when p_date=public.ist_today() and sp.spins>=10 then 'Tenth spin passed / no V8 speaker'
        when p_date=public.ist_today() and public._v8_user_enabled(c.id,u.id) then 'Waiting for tenth spin'
        else 'No scheduled speaker recorded' end as status,
      a.spin_id,spk.spin_code,spk.created_at as awarded_at,spk.redemption_status,
      public._v7_distribution_mode(u.id) is not null as ordinary_v7
    from public.prize_v8_users v join public.app_users u on u.id=v.user_id
    join public.campaigns c on c.code='RSW-2026'
    left join public.prize_v8_daily_awards a on a.user_id=v.user_id and a.biz_date=p_date
    left join public.spins spk on spk.id=a.spin_id
    left join lateral(select count(*) as spins from public.spins s where s.promoter_id=u.id and s.campaign_id=c.id and s.biz_date=p_date) sp on true
    where v.enabled
  ) q;
  return r;
end $report$;
revoke all on function public.get_prize_weekend_market_status(uuid),public.report_v8_speaker_users(date) from public,anon,authenticated;
grant execute on function public.get_prize_weekend_market_status(uuid),public.report_v8_speaker_users(date) to authenticated;

notify pgrst,'reload schema';
commit;
