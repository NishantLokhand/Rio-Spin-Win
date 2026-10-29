-- Version 7 expiry-stock allocation, 29 Oct through 4 Nov 2026 (inclusive, IST).
-- Run THIS file only in SQL Editor. Do not rerun the old dynamic V7 patches.
-- Transactional: a preflight error rolls back every change.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- The supplied working V6 body must still match, or this migration stops.
do $preflight$
declare v_source text; v_code text;
begin
  select p.prosrc into v_source from pg_proc p
   where p.oid = to_regprocedure('public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text)');
  if v_source is null then raise exception 'Working allocator is missing'; end if;
  if position('RIO_V7_DISPATCH_20261029' in v_source) = 0
     and md5(regexp_replace(v_source, '\s', '', 'g')) <> 'b0a70bcf36948bccb14a96cc8d2d8a21' then
    raise exception 'Allocator differs from the supplied working V6 snapshot; migration stopped without changes';
  end if;
  if not exists (select 1 from public.campaigns c where c.code='RSW-2026'
    and c.pool_scope='campaign' and c.track_inventory and not c.snack_launch_active and c.oos_mode='defer') then
    raise exception 'Expected inventory-tracked RSW-2026 campaign with campaign scope, launch off, and defer stock mode';
  end if;
  foreach v_code in array array['SNACK5','SNACK10','SHADES'] loop
    if not exists (select 1 from public.prize_configs pc
      join public.prize_config_items pci on pci.config_id=pc.id
      join public.prizes p on p.id=pci.prize_id
      join public.campaigns c on c.id=pc.campaign_id
      where c.code='RSW-2026' and pc.is_active and pc.state_id is null and pc.version=6
        and p.code=v_code and p.is_active) then
      raise exception 'Active default V6 config must contain prize %', v_code;
    end if;
  end loop;
end $preflight$;

-- A literal copy of the user-supplied V6 body. No SQL source rewriting.
CREATE OR REPLACE FUNCTION public._draw_cumulative_prize_v6_20261029(p_campaign campaigns, p_config prize_configs, p_promoter uuid, p_key text)
 RETURNS TABLE(prize_id uuid, unit_cost numeric, total_spins integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_alloc public.campaign_allocations;
  v_n int;
  v_cohort_n int;
  v_cohort_awarded jsonb;
  v_item record;
  v_eligible_count int;
  v_total_weight numeric := 0;
  v_r numeric;
  v_acc numeric := 0;
  v_won_prize uuid;
  v_won_cost numeric;
  v_target numeric;
  v_actual int;
  v_deficit numeric;
  v_stock int;
  v_best_deficit numeric := -999999;
  v_excluded uuid[] := '{}'::uuid[];
  v_attempt int := 0;
  v_special_campaign boolean := p_campaign.code = 'RSW-2026';
  v_shade_id uuid;
  v_shades_configured boolean := false;
  v_shade_eligible boolean := false;
begin
  -- The RSW campaign scope lock makes cohort totals shared across promoters.
  perform pg_advisory_xact_lock(hashtext('rio_alloc:' || p_campaign.id::text || ':' || p_campaign.pool_scope::text || ':' || p_key));

  if p_campaign.snack_launch_active and p_campaign.track_inventory and exists (
    select 1 from public.prizes p
     where p.code in ('SNACK5','SNACK10') and public._available(p_promoter,p.id) <= 0
  ) then
    raise exception 'OUT_OF_STOCK' using hint='Both snack prizes must be in stock during the temporary launch phase.';
  end if;

  if p_campaign.track_inventory and p_campaign.oos_mode = 'block' and exists (
    select 1 from public.prize_config_items i join public.prizes p on p.id=i.prize_id
     where i.config_id = p_config.id
       and (not p_campaign.snack_launch_active or p.code in ('SNACK5','SNACK10'))
       and coalesce(nullif(i.percentage, 0), i.quantity::numeric / p_config.pool_size * 100.0) > 0
       and public._available(p_promoter, i.prize_id) <= 0
  ) then
    raise exception 'OUT_OF_STOCK' using hint = 'Prize stock is temporarily unavailable. Please contact the supervisor.';
  end if;

  if v_special_campaign then
    select id into v_shade_id from public.prizes where code = 'SHADES';
    select exists (
      select 1 from public.prize_config_items i
       where i.config_id = p_config.id and i.prize_id = v_shade_id
         and coalesce(nullif(i.percentage, 0), i.quantity::numeric / p_config.pool_size * 100.0) > 0
    ) into v_shades_configured;
    v_shade_eligible := v_shades_configured
      and (not p_campaign.track_inventory or public._available(p_promoter, v_shade_id) > 0);
  end if;

  v_alloc := public._get_or_create_allocation(p_campaign.id, p_campaign.pool_scope, p_key);
  v_n := v_alloc.total_spins + 1;

  create temporary table if not exists _spin_candidates (
    p_id uuid,
    p_cost numeric,
    p_pct numeric,
    p_target numeric,
    p_actual int,
    p_deficit numeric,
    p_weight numeric,
    p_constrained boolean
  ) on commit drop;

  loop
    truncate table _spin_candidates;
    v_eligible_count := 0;
    v_total_weight := 0;
    v_acc := 0;
    v_best_deficit := -999999;
    v_won_prize := null;

    if v_special_campaign then
      if v_shade_eligible then
        v_cohort_n := v_alloc.shade_eligible_spins + 1;
        v_cohort_awarded := v_alloc.shade_eligible_awarded;
      else
        v_cohort_n := v_alloc.shade_ineligible_spins + 1;
        v_cohort_awarded := v_alloc.shade_ineligible_awarded;
      end if;
    else
      v_cohort_n := v_n;
      v_cohort_awarded := v_alloc.awarded;
    end if;

    for v_item in
      select i.prize_id, i.unit_cost, pz.code,
             case
               when v_special_campaign and v_shade_eligible then
                 coalesce(nullif(i.percentage,0), case when p_config.pool_size > 0 then i.quantity::numeric / p_config.pool_size::numeric * 100.0 else 0 end)
               when v_special_campaign and not v_shade_eligible and pz.code = 'SNACK5' then 75::numeric
               when v_special_campaign and not v_shade_eligible and pz.code = 'SNACK10' then 25::numeric
               when v_special_campaign then 0::numeric
               when p_campaign.snack_launch_active and pz.code = 'SNACK5' then 85::numeric
               when p_campaign.snack_launch_active and pz.code = 'SNACK10' then 15::numeric
               else coalesce(nullif(i.percentage,0), case when p_config.pool_size > 0 then i.quantity::numeric / p_config.pool_size::numeric * 100.0 else 0 end)
             end as pct
        from public.prize_config_items i
        join public.prizes pz on pz.id = i.prize_id
       where i.config_id = p_config.id and not (i.prize_id = any(v_excluded))
         and (not p_campaign.snack_launch_active or pz.code in ('SNACK5','SNACK10'))
       order by i.unit_cost desc
    loop
      if v_item.pct > 0 then
        v_stock := case when p_campaign.track_inventory then public._available(p_promoter, v_item.prize_id) else 99999 end;
        v_actual := coalesce((v_cohort_awarded->>v_item.prize_id::text)::int, 0);
        v_target := (v_cohort_n::numeric * v_item.pct) / 100.0;
        v_deficit := v_target - v_actual::numeric;
        if v_stock > 0 then
          v_eligible_count := v_eligible_count + 1;
          if v_deficit > v_best_deficit then v_best_deficit := v_deficit; end if;
          insert into _spin_candidates values (v_item.prize_id, v_item.unit_cost, v_item.pct, v_target, v_actual, v_deficit, 0, false);
        end if;
      end if;
    end loop;

    if v_eligible_count = 0 then
      raise exception 'OUT_OF_STOCK' using hint = 'No configured prize is available at this promoter.';
    end if;

    update _spin_candidates as candidate
       set p_constrained = candidate.p_deficit < v_best_deficit - 1.5,
           p_weight = (candidate.p_pct / 100.0) * exp(greatest(-4.0, least(0.0, (candidate.p_deficit - v_best_deficit) / 0.75)))
     where candidate.p_id is not null;
    select coalesce(sum(p_weight), 0) into v_total_weight from _spin_candidates where not p_constrained;
    if v_total_weight <= 0 then
      update _spin_candidates set p_constrained = false where p_constrained is distinct from false;
      select coalesce(sum(p_weight), 0) into v_total_weight from _spin_candidates;
    end if;

    v_r := ((('x' || encode(extensions.gen_random_bytes(6), 'hex'))::bit(48)::bigint)::numeric / 281474976710656) * v_total_weight;
    for v_item in select p_id, p_cost, p_weight from _spin_candidates where not p_constrained order by p_id loop
      v_acc := v_acc + v_item.p_weight;
      if v_r < v_acc then v_won_prize := v_item.p_id; v_won_cost := v_item.p_cost; exit; end if;
    end loop;
    if v_won_prize is null then
      select p_id, p_cost into v_won_prize, v_won_cost from _spin_candidates where not p_constrained order by p_weight desc limit 1;
    end if;

    if p_campaign.track_inventory then
      update public.promoter_inventory as inv set reserved = inv.reserved + 1, updated_at = now()
       where inv.promoter_id = p_promoter and inv.prize_id = v_won_prize and inv.on_hand - inv.reserved > 0;
      if not found then
        v_attempt := v_attempt + 1;
        if v_special_campaign and v_shade_eligible and v_won_prize = v_shade_id then
          -- Stock disappeared during reservation: count this draw in the no-shades cohort.
          v_shade_eligible := false;
          v_excluded := '{}'::uuid[];
        else
          v_excluded := array_append(v_excluded, v_won_prize);
        end if;
        if v_attempt < 100 then continue; end if;
        raise exception 'OUT_OF_STOCK' using hint = 'No configured prize could be reserved.';
      end if;
    end if;
    exit;
  end loop;

  perform set_config('rio.shade_eligible_draw',
    case when not v_special_campaign then 'na' when v_shade_eligible then 'true' else 'false' end, true);

  update public.campaign_allocations
     set total_spins = v_n,
         awarded = jsonb_set(awarded, array[v_won_prize::text], to_jsonb(coalesce((awarded->>v_won_prize::text)::int, 0) + 1)),
         shade_eligible_spins = shade_eligible_spins + case when v_special_campaign and v_shade_eligible then 1 else 0 end,
         shade_eligible_awarded = case when v_special_campaign and v_shade_eligible
           then jsonb_set(shade_eligible_awarded, array[v_won_prize::text], to_jsonb(coalesce((shade_eligible_awarded->>v_won_prize::text)::int, 0) + 1))
           else shade_eligible_awarded end,
         shade_ineligible_spins = shade_ineligible_spins + case when v_special_campaign and not v_shade_eligible then 1 else 0 end,
         shade_ineligible_awarded = case when v_special_campaign and not v_shade_eligible
           then jsonb_set(shade_ineligible_awarded, array[v_won_prize::text], to_jsonb(coalesce((shade_ineligible_awarded->>v_won_prize::text)::int, 0) + 1))
           else shade_ineligible_awarded end,
         updated_at = now()
   where id = v_alloc.id;

  prize_id := v_won_prize;
  unit_cost := v_won_cost;
  total_spins := v_n;
  return next;
end $function$;

revoke all on function public._draw_cumulative_prize_v6_20261029(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;

create table if not exists public.prize_user_distribution_overrides (
  user_id uuid primary key references public.app_users(id) on delete cascade,
  mode text not null check (mode in ('snacks','shades','no_snack5')),
  version integer not null default 7,
  starts_on date not null default public.ist_today(),
  expires_on date not null,
  notes text,
  created_at timestamptz not null default now()
);
alter table public.prize_user_distribution_overrides enable row level security;
revoke all on public.prize_user_distribution_overrides from public,anon,authenticated;

create table if not exists public.prize_v7_settings (
  campaign_id uuid primary key references public.campaigns(id),
  enabled boolean not null default false,
  starts_on date not null,
  expires_on date not null check (expires_on>=starts_on),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.app_users(id)
);
create table if not exists public.prize_v7_allocations (
  campaign_id uuid not null references public.campaigns(id),
  mode text not null check (mode in ('snacks','shades','no_snack5','no_snack5_no_shades')),
  total_spins integer not null default 0 check (total_spins>=0),
  snack5_awarded integer not null default 0 check (snack5_awarded>=0),
  snack10_awarded integer not null default 0 check (snack10_awarded>=0),
  shades_awarded integer not null default 0 check (shades_awarded>=0),
  updated_at timestamptz not null default now(),
  primary key (campaign_id,mode),
  check (total_spins=snack5_awarded+snack10_awarded+shades_awarded)
);
alter table public.prize_v7_settings enable row level security;
alter table public.prize_v7_allocations enable row level security;
revoke all on public.prize_v7_settings,public.prize_v7_allocations from public,anon,authenticated;

-- Keep the 41-person allowlist explicit. Every name must match exactly one
-- active field login after case/spacing/punctuation normalization.
create temporary table _v7_requested_20261029(name text primary key, mode text not null) on commit drop;
insert into _v7_requested_20261029 values
 ('KARAN KALE','snacks'),('VICKY DHARMA KALE','snacks'),('DIPAK LONDHE','snacks'),
 ('ANAND PARDE','shades'),('AJIT BHAGOJI SHINDE','snacks'),('RUSHABH JANARDHAN SHINDE','snacks'),
 ('SHIVKUMAR NARAYANRAO KALYANI','snacks'),('PRAMOD MOHITE','shades'),
 ('SATISH RANGRAO PATIL','shades'),('SUDHAKAR JADHAV MER KOH','shades'),
 ('GANESH RAJENDRA KULAT','shades'),('PARIKSHIT VEMULKAR','snacks'),('SUMIT GARSUND','snacks'),
 ('SAGAR SHANKAR GUTHAL','snacks'),('CHETAN MADHUKAR PAUNIKAR','snacks'),('NIKHIL KAROTE','snacks'),
 ('AJAY PANDURANG DOLEKAR','snacks'),('VISHAL VIKRAM PATIL','snacks'),
 ('TUKARAM PITAMBER DEORE','no_snack5'),('NAYAN ANIL MARATHE','no_snack5'),
 ('RAKESH CHANDRAKANT HOLKAR','snacks'),('SHEKHAR POPAT SHINDE','snacks'),
 ('VIKRANT SADANAPUR','snacks'),('ARUN BHAGWAN BHANDARE MER AHM','snacks'),
 ('ANIL BALASAHEB KACHARE','snacks'),('PAVAN PANBIHADE','snacks'),('SARANG R BORKAR','shades'),
 ('MANOJ DEVIDAS JADHAV','snacks'),('SAURABH PATIL','shades'),('SURAJ SANJAY BHATKAR','snacks'),
 ('VAIBHAV KURWADE','snacks'),('SUNNY SONEKMBALE','snacks'),('SIDDHARAM B KHANDE','snacks'),
 ('SUJAL KALIDAS WANKHEDE','snacks'),('ASHISH RAMU KALWAL','snacks'),('VIVEK DHARMADHIKARI','snacks'),
 ('ROHAN RATHOD','snacks'),('VIKAS SHRIKRUSHANA TAYADE','snacks'),('PRIYANSHU PAWAR','shades'),
 ('VISHAL VILAS TRIBHUVAN','shades'),('OMKAR VALUSA','snacks');

do $matches$
declare v_bad text;
begin
  select string_agg(q.name || ' (' || q.matches || ' matches)', ', ') into v_bad
  from (
    select r.name,count(u.id) as matches from _v7_requested_20261029 r
    left join public.app_users u
      on regexp_replace(upper(u.full_name),'[^A-Z0-9]','','g')=regexp_replace(r.name,'[^A-Z0-9]','','g')
      and u.role='promoter' and u.is_active
      and exists (select 1 from public.promoters pr where pr.user_id=u.id)
    group by r.name
  ) q where q.matches<>1;
  if v_bad is not null then
    raise exception 'V7 allowlist validation failed; no changes committed: %',v_bad;
  end if;
end $matches$;

insert into public.prize_user_distribution_overrides as existing
  (user_id,mode,version,starts_on,expires_on,notes)
select u.id,r.mode,7,date '2026-10-29',date '2026-11-04',
  'V7 expiry campaign: snacks 95/5; shades 90/6/4; no-5 96/4; effective 29 Oct 2026'
from _v7_requested_20261029 r join public.app_users u
  on regexp_replace(upper(u.full_name),'[^A-Z0-9]','','g')=regexp_replace(r.name,'[^A-Z0-9]','','g')
where u.role='promoter' and u.is_active
on conflict (user_id) do update
set mode=excluded.mode,version=7,starts_on=excluded.starts_on,expires_on=excluded.expires_on,notes=excluded.notes
where existing.user_id=excluded.user_id;

-- Supersede any old extra override records, without deleting their history.
update public.prize_user_distribution_overrides o set expires_on=date '2026-10-28'
where o.version=7 and o.expires_on>=date '2026-10-29'
  and not exists (
    select 1 from _v7_requested_20261029 r join public.app_users u
      on regexp_replace(upper(u.full_name),'[^A-Z0-9]','','g')=regexp_replace(r.name,'[^A-Z0-9]','','g')
    where u.id=o.user_id and u.role='promoter' and u.is_active
  );

insert into public.prize_v7_settings(campaign_id,enabled,starts_on,expires_on)
select c.id,true,date '2026-10-29',date '2026-11-04' from public.campaigns c where c.code='RSW-2026'
on conflict (campaign_id) do nothing; -- Rerunning must not re-enable a disabled rollout.

create or replace function public._v7_distribution_mode(p_user uuid)
returns text language sql stable security definer set search_path=public as $mode$
  select o.mode from public.prize_user_distribution_overrides o
  join public.app_users u on u.id=o.user_id and u.is_active and u.role='promoter'
  join public.prize_v7_settings vs on vs.enabled
  join public.campaigns c on c.id=vs.campaign_id and c.code='RSW-2026'
  where o.user_id=p_user and o.version=7
    and public.ist_today() between o.starts_on and o.expires_on
    and public.ist_today() between vs.starts_on and vs.expires_on
$mode$;
revoke all on function public._v7_distribution_mode(uuid) from public,anon,authenticated;

-- New allocator uses only the V7 tables. V6's allocation counters remain intact.
create or replace function public._draw_prize_v7_20261029(
  p_campaign public.campaigns,p_config public.prize_configs,p_promoter uuid,p_override text
)
returns table(prize_id uuid,unit_cost numeric,total_spins integer)
language plpgsql security definer set search_path=public,extensions as $v7$
declare
  v_five uuid; v_ten uuid; v_shade uuid;
  v_five_cost numeric; v_ten_cost numeric; v_shade_cost numeric;
  v_mode text; v_shade_available boolean; v_alloc public.prize_v7_allocations;
  v_n integer; v_shade_cap integer; v_random numeric;
  v_five_weight integer; v_ten_weight integer;
  v_prize uuid; v_cost numeric; v_attempt integer;
begin
  if p_override not in ('snacks','shades','no_snack5') or p_override is null then
    raise exception 'Invalid Version 7 rule';
  end if;
  perform pg_advisory_xact_lock(hashtext('rio_v7:'||p_campaign.id::text));
  select p.id,i.unit_cost into v_five,v_five_cost
    from public.prizes p join public.prize_config_items i on i.prize_id=p.id
    where p.code='SNACK5' and p.is_active and i.config_id=p_config.id;
  select p.id,i.unit_cost into v_ten,v_ten_cost
    from public.prizes p join public.prize_config_items i on i.prize_id=p.id
    where p.code='SNACK10' and p.is_active and i.config_id=p_config.id;
  select p.id,i.unit_cost into v_shade,v_shade_cost
    from public.prizes p join public.prize_config_items i on i.prize_id=p.id
    where p.code='SHADES' and p.is_active and i.config_id=p_config.id;
  if v_ten is null or v_five is null or v_shade is null then raise exception 'NO_PRIZE_CONFIG'; end if;

  for v_attempt in 1..5 loop
    if public._available(p_promoter,v_ten)<=0 then
      raise exception 'OUT_OF_STOCK' using hint='Replenish the promoter''s ₹10 snack stock.';
    end if;
    if p_override<>'no_snack5' and public._available(p_promoter,v_five)<=0 then
      raise exception 'OUT_OF_STOCK' using hint='Replenish the promoter''s ₹5 snack stock.';
    end if;
    v_shade_available:=public._available(p_promoter,v_shade)>0;
    v_mode:=case when p_override='no_snack5'
      then case when v_shade_available then 'no_snack5' else 'no_snack5_no_shades' end
      when v_shade_available then 'shades' else 'snacks' end;
    v_five_weight:=case v_mode when 'snacks' then 5 when 'shades' then 6 else 0 end;
    v_ten_weight:=case v_mode when 'snacks' then 95 when 'shades' then 90
      when 'no_snack5' then 96 else 100 end;
    insert into public.prize_v7_allocations(campaign_id,mode) values(p_campaign.id,v_mode)
      on conflict (campaign_id,mode) do nothing;
    select a.* into strict v_alloc from public.prize_v7_allocations a
      where a.campaign_id=p_campaign.id and a.mode=v_mode for update;
    v_n:=v_alloc.total_spins+1;
    -- Rounded cap permits an early random shade, at most four by spin 100.
    -- No scheduled prize positions and no deficit/catch-up shade streaks.
    v_shade_cap:=ceil(v_n::numeric*0.04)::integer;
    v_random:=((('x'||encode(extensions.gen_random_bytes(6),'hex'))::bit(48)::bigint)::numeric/281474976710656);
    if v_shade_available and v_alloc.shades_awarded<v_shade_cap and v_random<0.04 then
      v_prize:=v_shade; v_cost:=v_shade_cost;
    else
      v_random:=((('x'||encode(extensions.gen_random_bytes(6),'hex'))::bit(48)::bigint)::numeric/281474976710656);
      if v_random*(v_five_weight+v_ten_weight)<v_five_weight then
        v_prize:=v_five; v_cost:=v_five_cost;
      else v_prize:=v_ten; v_cost:=v_ten_cost;
      end if;
    end if;

    update public.promoter_inventory as inv set reserved=inv.reserved+1,updated_at=now()
      where inv.promoter_id=p_promoter and inv.prize_id=v_prize and inv.on_hand-inv.reserved>0;
    if not found then continue; end if;
    update public.prize_v7_allocations as a
      set total_spins=v_n,
          snack5_awarded=a.snack5_awarded+case when v_prize=v_five then 1 else 0 end,
          snack10_awarded=a.snack10_awarded+case when v_prize=v_ten then 1 else 0 end,
          shades_awarded=a.shades_awarded+case when v_prize=v_shade then 1 else 0 end,
          updated_at=now()
      where a.campaign_id=p_campaign.id and a.mode=v_mode;
    perform set_config('rio.shade_eligible_draw',case when v_shade_available then 'true' else 'false' end,true);
    perform set_config('rio.distribution_mode',v_mode,true);
    prize_id:=v_prize; unit_cost:=v_cost; total_spins:=v_n; return next; return;
  end loop;
  raise exception 'OUT_OF_STOCK' using hint='Prize stock changed during the draw. Please retry.';
end $v7$;
revoke all on function public._draw_prize_v7_20261029(public.campaigns,public.prize_configs,uuid,text) from public,anon,authenticated;

-- This keeps the original RPC-facing function identity and signature.
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

-- Preserve the actual distribution version separately from the base config ID.
alter table public.spins add column if not exists distribution_version integer;
alter table public.spins add column if not exists distribution_mode text;
create or replace function public._stamp_spin_distribution_v7()
returns trigger language plpgsql security definer set search_path=public as $stamp$
begin
  if current_setting('rio.distribution_version',true) in ('6','7') then
    new.distribution_version:=current_setting('rio.distribution_version',true)::integer;
    new.distribution_mode:=nullif(current_setting('rio.distribution_mode',true),'');
  end if;
  return new;
end $stamp$;
revoke all on function public._stamp_spin_distribution_v7() from public,anon,authenticated;
drop trigger if exists stamp_spin_distribution_v7 on public.spins;
create trigger stamp_spin_distribution_v7 before insert on public.spins
  for each row execute function public._stamp_spin_distribution_v7();

create or replace function public.get_prize_v7_status(p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $status$
declare v_result jsonb;
begin
  perform public._require_staff();
  select jsonb_build_object('enabled',s.enabled,'starts_on',s.starts_on,'expires_on',s.expires_on,
    'effective',s.enabled and public.ist_today() between s.starts_on and s.expires_on,
    'selected_users',(select count(*) from public.prize_user_distribution_overrides o
      where o.version=7 and public.ist_today() between o.starts_on and o.expires_on),
    'rules',jsonb_build_object('snacks','95% ₹10 / 5% ₹5','shades','90% ₹10 / 6% ₹5 / 4% shades',
      'no_snack5','96% ₹10 / 4% shades'))
    into v_result from public.prize_v7_settings s where s.campaign_id=p_campaign;
  return v_result;
end $status$;
create or replace function public.set_prize_v7_enabled(p_campaign uuid,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path=public as $toggle$
declare v_user public.app_users;
begin
  v_user:=public._require_staff();
  if v_user.role<>'admin' then raise exception 'ADMIN_ONLY'; end if;
  if p_enabled is null then raise exception 'Enabled must be true or false'; end if;
  update public.prize_v7_settings s set enabled=p_enabled,updated_at=now(),updated_by=v_user.id
    where s.campaign_id=p_campaign;
  if not found then raise exception 'Version 7 is not installed for this campaign'; end if;
  perform public.write_audit('PRIZE_V7_TOGGLED','campaigns',p_campaign::text,jsonb_build_object('enabled',p_enabled));
  return public.get_prize_v7_status(p_campaign);
end $toggle$;
revoke all on function public.get_prize_v7_status(uuid),public.set_prize_v7_enabled(uuid,boolean) from public,anon,authenticated;
grant execute on function public.get_prize_v7_status(uuid),public.set_prize_v7_enabled(uuid,boolean) to authenticated;

create or replace function public.report_v7_expiry_users()
returns jsonb language plpgsql stable security definer set search_path=public as $report$
declare v_result jsonb;
begin
  perform public._require_staff();
  select coalesce(jsonb_agg(to_jsonb(r) order by r.full_name),'[]'::jsonb) into v_result
  from (
    select o.user_id,u.full_name,u.login_id,o.mode,
      public._v7_distribution_mode(o.user_id) is not null as enabled,
      case when o.mode='no_snack5' then
        case when coalesce(st.shades,0)>0 then '96% ₹10 / 4% shades' else '100% ₹10 (shades empty)' end
        when coalesce(st.shades,0)>0 then '90% ₹10 / 6% ₹5 / 4% shades'
        else '95% ₹10 / 5% ₹5' end as effective_rule,
      o.starts_on,o.expires_on,
      coalesce((select op.state_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as state,
      coalesce((select op.market_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as city,
      coalesce((select op.area_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as area,
      st.stock,coalesce(sp.spins,0) as spins,coalesce(sp.giveaway_cost,0) as giveaway_cost,
      coalesce(sp.snack5_used,0) as snack5_used,coalesce(sp.snack10_used,0) as snack10_used,
      coalesce(sp.shades_used,0) as shades_used
    from public.prize_user_distribution_overrides o join public.app_users u on u.id=o.user_id
    left join lateral (
      select jsonb_object_agg(p.code,pi.on_hand-pi.reserved) as stock,
        max(pi.on_hand-pi.reserved) filter(where p.code='SHADES') as shades
      from public.promoter_inventory pi join public.prizes p on p.id=pi.prize_id
      where pi.promoter_id=u.id and p.code in ('SNACK5','SNACK10','SHADES')
    ) st on true
    left join lateral (
      select count(*) as spins,coalesce(sum(s.prize_cost),0) as giveaway_cost,
        count(*) filter(where s.prize_code='SNACK5') as snack5_used,
        count(*) filter(where s.prize_code='SNACK10') as snack10_used,
        count(*) filter(where s.prize_code='SHADES') as shades_used
      from public.spins s where s.promoter_id=u.id and s.distribution_version=7
        and s.biz_date between o.starts_on and o.expires_on and s.redemption_status<>'not_redeemed'
    ) sp on true
    where o.version=7 and o.expires_on>=date '2026-10-29'
  ) r;
  return v_result;
end $report$;
revoke all on function public.report_v7_expiry_users() from public,anon,authenticated;
grant execute on function public.report_v7_expiry_users() to authenticated;

-- Verify the literal V6 copy before committing the new dispatcher.
do $verify$
begin
  if (select md5(regexp_replace(p.prosrc,'\s','','g')) from pg_proc p
    where p.oid=to_regprocedure('public._draw_cumulative_prize_v6_20261029(public.campaigns,public.prize_configs,uuid,text)'))
      <> 'b0a70bcf36948bccb14a96cc8d2d8a21' then
    raise exception 'V6 snapshot verification failed';
  end if;
  raise notice 'V7 installed: 41 selected users; V6 function body preserved; automatically expires after 4 Nov 2026 IST';
end $verify$;
notify pgrst,'reload schema';
commit;
