-- Version 8: one scheduled speaker on each selected user's third daily spin.
-- Installs DISABLED. No inventory is issued or replenished by this migration.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $preflight$
declare v_source text;
begin
  select prosrc into v_source from pg_proc where oid=to_regprocedure('public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text)');
  if v_source is null or (position('RIO_V8_DISPATCH_20261029' in v_source)=0
    and md5(regexp_replace(v_source,'\s','','g'))<>'d57efbacd4d8c4162a8d566fe5d2df37') then
    raise exception 'Current allocator differs from the verified V7 dispatcher; no changes committed';
  end if;
  select prosrc into v_source from pg_proc where oid=to_regprocedure('public._stock_problem(public.campaigns,public.prize_configs,uuid,text)');
  if v_source is null or (position('RIO_V8_STOCK_GATE_20261029' in v_source)=0
    and md5(regexp_replace(v_source,'\s','','g'))<>'3181b752940afd6b37864aa2cfc402ee') then
    raise exception 'Current stock-readiness helper differs from verified baseline; no changes committed';
  end if;
  if not exists(select 1 from public.campaigns where code='RSW-2026' and track_inventory and not snack_launch_active) then
    raise exception 'Expected inventory-tracked RSW-2026 campaign with launch phase off';
  end if;
  if not exists(select 1 from public.prizes where code='SPEAKER' and is_active) then
    raise exception 'Active SPEAKER catalogue entry is required';
  end if;
end $preflight$;

-- Literal copies of the working routes. No runtime rewriting of function bodies.
CREATE OR REPLACE FUNCTION public._stock_problem_pre_v8_20261029(c campaigns, p_config prize_configs, p_promoter uuid, p_key text)
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

revoke all on function public._stock_problem_pre_v8_20261029(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;
create or replace function public._draw_prize_pre_v8_20261029(
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
revoke all on function public._draw_prize_pre_v8_20261029(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;



create table if not exists public.prize_v8_settings(
  campaign_id uuid primary key references public.campaigns(id),
  enabled boolean not null default false,
  starts_on date not null default public.ist_today(),
  expires_on date check(expires_on is null or expires_on>=starts_on),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.app_users(id)
);
create table if not exists public.prize_v8_users(
  user_id uuid primary key references public.app_users(id),
  reported_speakers integer not null check(reported_speakers>0),
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.prize_v8_daily_awards(
  user_id uuid not null references public.app_users(id),
  biz_date date not null,
  campaign_id uuid not null references public.campaigns(id),
  prize_id uuid not null references public.prizes(id),
  spin_id uuid unique references public.spins(id),
  awarded_at timestamptz not null default now(),
  primary key(user_id,biz_date)
);
alter table public.prize_v8_settings enable row level security;
alter table public.prize_v8_users enable row level security;
alter table public.prize_v8_daily_awards enable row level security;
revoke all on public.prize_v8_settings,public.prize_v8_users,public.prize_v8_daily_awards from public,anon,authenticated;

create temporary table _v8_requested_20261029(name text primary key,qty integer not null) on commit drop;
insert into _v8_requested_20261029 values
 ('AJAY PANDURANG DOLEKAR',6),('KARAN KALE',6),('SUNIL KUMAR YADAV',10),
 ('VIVEK DHARMADHIKARI',6),('ROHAN RATHOD',7),('VIKAS SHRIKRUSHANA TAYADE',7),
 ('HARISHACHANDRA PATEL',10),('NIKHIL KAROTE',7),('CHETAN MADHUKAR PAUNIKAR',7),
 ('PAVAN PANBIHADE',6),('SARANG R BORKAR',7),('SAURABH PATIL',7);
-- Pradeep Bharadwaj is intentionally omitted.
do $users$
declare v_bad text;
begin
  select string_agg(q.name||' ('||q.matches||' matches)',', ') into v_bad from (
    select r.name,count(u.id) as matches from _v8_requested_20261029 r
    left join public.app_users u on u.role='promoter' and u.is_active
      and regexp_replace(upper(u.full_name),'[^A-Z0-9]','','g')=regexp_replace(r.name,'[^A-Z0-9]','','g')
      and exists(select 1 from public.promoters pr where pr.user_id=u.id)
    group by r.name
  ) q where q.matches<>1;
  if v_bad is not null then raise exception 'V8 exact user match failed; no changes committed: %',v_bad; end if;
end $users$;
insert into public.prize_v8_users as existing(user_id,reported_speakers)
select u.id,r.qty from _v8_requested_20261029 r join public.app_users u
  on regexp_replace(upper(u.full_name),'[^A-Z0-9]','','g')=regexp_replace(r.name,'[^A-Z0-9]','','g')
where u.role='promoter' and u.is_active
on conflict(user_id) do update set reported_speakers=excluded.reported_speakers where existing.user_id=excluded.user_id;
insert into public.prize_v8_settings(campaign_id)
select id from public.campaigns where code='RSW-2026'
on conflict(campaign_id) do nothing;

create or replace function public._v8_user_enabled(p_campaign uuid,p_user uuid)
returns boolean language sql stable security definer set search_path=public as $enabled$
  select exists(
    select 1 from public.prize_v8_settings s join public.campaigns c on c.id=s.campaign_id and c.code='RSW-2026'
    join public.prize_v8_users v on v.user_id=p_user and v.enabled
    join public.app_users u on u.id=v.user_id and u.is_active and u.role='promoter'
    where s.campaign_id=p_campaign and s.enabled and public.ist_today()>=s.starts_on
      and (s.expires_on is null or public.ist_today()<=s.expires_on)
  )
$enabled$;
create or replace function public._v8_speaker_due(p_campaign uuid,p_user uuid)
returns boolean language sql stable security definer set search_path=public as $due$
  select public._v8_user_enabled(p_campaign,p_user)
    and (select count(*) from public.spins sp
      where sp.promoter_id=p_user and sp.campaign_id=p_campaign and sp.biz_date=public.ist_today())=2
    and not exists(select 1 from public.prize_v8_daily_awards a where a.user_id=p_user and a.biz_date=public.ist_today())
    and not exists(select 1 from public.spins sp join public.prizes p on p.id=sp.prize_id
      where sp.promoter_id=p_user and sp.biz_date=public.ist_today() and p.code='SPEAKER')
$due$;
revoke all on function public._v8_user_enabled(uuid,uuid),public._v8_speaker_due(uuid,uuid) from public,anon,authenticated;

-- Readiness exception only when an in-stock speaker is due on this next spin.
create or replace function public._stock_problem(c public.campaigns,p_config public.prize_configs,p_promoter uuid,p_key text)
returns text language plpgsql stable security definer set search_path=public as $stock$
begin
  -- RIO_V8_STOCK_GATE_20261029
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
  -- Serializes different bills/devices for this user through spin insertion.
  perform pg_advisory_xact_lock(hashtextextended('rio_v8:'||p_promoter::text||':'||v_today::text,0));
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
        perform set_config('rio.distribution_mode','speaker_third_daily',true);
        perform set_config('rio.shade_eligible_draw','na',true);
        select count(*)::integer+1 into v_total from public.spins sp
          where sp.promoter_id=p_promoter and sp.campaign_id=p_campaign.id and sp.biz_date=v_today;
        prize_id:=v_speaker; unit_cost:=v_cost; total_spins:=v_total; return next; return;
      end if;
    end if;
  end if;
  -- Empty speaker stock at spin 3 is an ordinary prize. No catch-up on spin 4+.
  return query select d.* from public._draw_prize_pre_v8_20261029(p_campaign,p_config,p_promoter,p_key) d;
end $draw$;
revoke all on function public._draw_prize_v8_20261029(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;

create or replace function public._draw_cumulative_prize(
  p_campaign public.campaigns,p_config public.prize_configs,p_promoter uuid,p_key text
)
returns table(prize_id uuid,unit_cost numeric,total_spins integer)
language plpgsql security definer set search_path=public,extensions as $dispatch$
begin
  -- RIO_V8_DISPATCH_20261029
  if public._v8_user_enabled(p_campaign.id,p_promoter) then
    return query select d.* from public._draw_prize_v8_20261029(p_campaign,p_config,p_promoter,p_key) d;
  else
    return query select d.* from public._draw_prize_pre_v8_20261029(p_campaign,p_config,p_promoter,p_key) d;
  end if;
end $dispatch$;
revoke all on function public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;

create or replace function public._stamp_spin_distribution_v7()
returns trigger language plpgsql security definer set search_path=public as $stamp$
begin
  if current_setting('rio.distribution_version',true) in ('6','7','8') then
    new.distribution_version:=current_setting('rio.distribution_version',true)::integer;
    new.distribution_mode:=nullif(current_setting('rio.distribution_mode',true),'');
  end if;
  return new;
end $stamp$;
revoke all on function public._stamp_spin_distribution_v7() from public,anon,authenticated;

create or replace function public._link_v8_speaker_award()
returns trigger language plpgsql security definer set search_path=public as $link$
begin
  if new.distribution_version=8 then
    if new.prize_code<>'SPEAKER' then raise exception 'Invalid scheduled V8 prize'; end if;
    update public.prize_v8_daily_awards a set spin_id=new.id
      where a.user_id=new.promoter_id and a.biz_date=new.biz_date and a.campaign_id=new.campaign_id
        and a.prize_id=new.prize_id and a.spin_id is null;
    if not found then raise exception 'Scheduled V8 daily award missing'; end if;
  end if;
  return new;
end $link$;
revoke all on function public._link_v8_speaker_award() from public,anon,authenticated;
drop trigger if exists link_v8_speaker_award on public.spins;
create trigger link_v8_speaker_award after insert on public.spins for each row execute function public._link_v8_speaker_award();

create or replace function public.get_prize_v8_status(p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $status$
declare r jsonb;
begin
  perform public._require_staff();
  select jsonb_build_object('enabled',s.enabled,'starts_on',s.starts_on,'expires_on',s.expires_on,
    'effective',s.enabled and public.ist_today()>=s.starts_on and (s.expires_on is null or public.ist_today()<=s.expires_on),
    'selected_users',(select count(*) from public.prize_v8_users where enabled),
    'speakers_awarded_today',(select count(*) from public.prize_v8_daily_awards a where a.campaign_id=p_campaign and a.biz_date=public.ist_today()))
  into r from public.prize_v8_settings s where s.campaign_id=p_campaign;
  return r;
end $status$;
create or replace function public.set_prize_v8_enabled(p_campaign uuid,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path=public as $toggle$
declare u public.app_users;
begin
  u:=public._require_staff();
  if u.role<>'admin' then raise exception 'ADMIN_ONLY'; end if;
  if p_enabled is null then raise exception 'Enabled must be true or false'; end if;
  update public.prize_v8_settings s set enabled=p_enabled,updated_at=now(),updated_by=u.id where s.campaign_id=p_campaign;
  if not found then raise exception 'Version 8 is not installed for this campaign'; end if;
  perform public.write_audit('PRIZE_V8_TOGGLED','campaigns',p_campaign::text,jsonb_build_object('enabled',p_enabled));
  return public.get_prize_v8_status(p_campaign);
end $toggle$;
revoke all on function public.get_prize_v8_status(uuid),public.set_prize_v8_enabled(uuid,boolean) from public,anon,authenticated;
grant execute on function public.get_prize_v8_status(uuid),public.set_prize_v8_enabled(uuid,boolean) to authenticated;

create or replace function public.report_v8_speaker_users(p_date date default public.ist_today())
returns jsonb language plpgsql stable security definer set search_path=public as $report$
declare r jsonb;
begin
  perform public._require_staff();
  select coalesce(jsonb_agg(to_jsonb(q) order by q.full_name),'[]'::jsonb) into r from (
    select v.user_id,u.full_name,p_date as date,v.reported_speakers,
      coalesce((select op.state_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as state,
      coalesce((select op.market_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as city,
      coalesce((select op.area_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as area,
      coalesce((select pi.on_hand-pi.reserved from public.promoter_inventory pi join public.prizes p on p.id=pi.prize_id where pi.promoter_id=u.id and p.code='SPEAKER'),0) as speakers_remaining,
      sp.spins as spins_today,
      case when a.spin_id is not null then 'Speaker awarded'
        when sp.spins>=3 then 'Third spin passed / no V8 speaker'
        when p_date=public.ist_today() and public._v8_user_enabled(c.id,u.id) then 'Waiting for third spin'
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
revoke all on function public.report_v8_speaker_users(date) from public,anon,authenticated;
grant execute on function public.report_v8_speaker_users(date) to authenticated;

do $verify$
begin
  if (select md5(regexp_replace(prosrc,'\s','','g')) from pg_proc where oid='public._draw_prize_pre_v8_20261029(public.campaigns,public.prize_configs,uuid,text)'::regprocedure)<>'d57efbacd4d8c4162a8d566fe5d2df37' then raise exception 'Original V7 route copy verification failed'; end if;
  if (select md5(regexp_replace(prosrc,'\s','','g')) from pg_proc where oid='public._stock_problem_pre_v8_20261029(public.campaigns,public.prize_configs,uuid,text)'::regprocedure)<>'3181b752940afd6b37864aa2cfc402ee' then raise exception 'Original stock gate copy verification failed'; end if;
  raise notice 'V8 installed; 12 exact users, reported stock 86, inventory untouched. V8 remains disabled until admin activation.';
end $verify$;
notify pgrst,'reload schema';
commit;
