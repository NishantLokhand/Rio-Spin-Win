-- Temporary expiry-stock allocation. Run this migration once in Supabase.
-- Version 6 remains the default for every user not listed below.

create table if not exists public.prize_user_distribution_overrides (
  user_id uuid primary key references public.app_users(id) on delete cascade,
  mode text not null check (mode in ('snacks','shades','no_snack5')),
  version integer not null default 7,
  starts_on date not null default public.ist_today(),
  expires_on date not null,
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists prize_user_distribution_overrides_active_idx
  on public.prize_user_distribution_overrides (expires_on, mode);

alter table public.prize_user_distribution_overrides enable row level security;
drop policy if exists prize_user_distribution_overrides_staff on public.prize_user_distribution_overrides;
create policy prize_user_distribution_overrides_staff on public.prize_user_distribution_overrides
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- Resolve by normalized full name so harmless spacing/case differences do not
-- prevent the migration. No loose partial-name matching is used.
do $$
declare
  v_count integer;
begin
  with requested(name, mode) as (values
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
    ('VISHAL VILAS TRIBHUVAN','shades'),('OMKAR VALUSA','snacks')
  ), normalized as (
    select regexp_replace(upper(name),'[^A-Z0-9]','','g') as norm, mode from requested
  ), matched as (
    select u.id, n.mode
    from public.app_users u join normalized n
      on regexp_replace(upper(u.full_name),'[^A-Z0-9]','','g') = n.norm
    where u.role = 'promoter'
  )
  insert into public.prize_user_distribution_overrides(user_id, mode, version, starts_on, expires_on, notes)
  select id, mode, 7, public.ist_today(), date '2026-11-04', 'Temporary expiry-stock allocation; review after 2026-11-04'
  from matched
  on conflict (user_id) do update set mode=excluded.mode, version=7, starts_on=excluded.starts_on,
    expires_on=excluded.expires_on, notes=excluded.notes;

  select count(*) into v_count from public.prize_user_distribution_overrides where version=7 and expires_on=date '2026-11-04';
  if v_count <> 41 then raise exception 'Expected 41 exact Version 7 user matches, found %; no allocation change is safe', v_count; end if;
end $$;

create or replace function public._v7_distribution_mode(p_user uuid)
returns text language sql stable security definer set search_path=public as $$
  select mode from public.prize_user_distribution_overrides
   where user_id=p_user and starts_on <= public.ist_today() and expires_on >= public.ist_today() and version=7
$$;
revoke all on function public._v7_distribution_mode(uuid) from public, anon;
grant execute on function public._v7_distribution_mode(uuid) to authenticated;

create or replace function public.report_v7_expiry_users()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result jsonb;
begin
  perform public._require_staff();
  select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name), '[]'::jsonb) into result
  from (
    select o.user_id, u.full_name, u.login_id, o.mode, o.starts_on, o.expires_on,
      coalesce(op.state_raw,'') as state, coalesce(op.market_raw,'') as city, coalesce(op.area_raw,'') as area,
      coalesce((select count(*) from public.spins s where s.promoter_id=o.user_id and s.biz_date between o.starts_on and o.expires_on),0)::int as spins,
      coalesce((select sum(s.prize_cost) from public.spins s where s.promoter_id=o.user_id and s.biz_date between o.starts_on and o.expires_on),0)::numeric as giveaway_cost,
      coalesce((select jsonb_object_agg(p.code, (pi.on_hand-pi.reserved)) from public.promoter_inventory pi join public.prizes p on p.id=pi.prize_id where pi.promoter_id=o.user_id and p.code in ('SNACK5','SNACK10','SHADES')), '{}'::jsonb) as stock
    from public.prize_user_distribution_overrides o
    join public.app_users u on u.id=o.user_id
    left join public.org_people op on op.auth_user_id=o.user_id
    where o.version=7 and o.expires_on >= o.starts_on
  ) x;
  return result;
end $$;
revoke all on function public.report_v7_expiry_users() from public, anon;
grant execute on function public.report_v7_expiry_users() to authenticated;

-- Patch the existing cumulative allocator without changing the Version 6 path.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='_draw_cumulative_prize' and p.pronargs=4
   order by p.oid desc limit 1;
  if d is null then raise exception 'Current cumulative prize allocator is missing'; end if;
  d := replace(d,
    'if p_campaign.snack_launch_active and p_campaign.track_inventory and exists (',
    'if p_campaign.snack_launch_active and public._v7_distribution_mode(p_promoter) is null and p_campaign.track_inventory and exists (');
  d := replace(d,
    'if p_campaign.track_inventory and p_campaign.oos_mode = ''block'' and exists (',
    'if p_campaign.track_inventory and public._v7_distribution_mode(p_promoter) is null and p_campaign.oos_mode = ''block'' and exists (');
  d := replace(d,
    'when v_special_campaign and v_shade_eligible then',
    E'when public._v7_distribution_mode(p_promoter) = ''no_snack5'' and pz.code = ''SNACK10'' then 96::numeric\n               when public._v7_distribution_mode(p_promoter) = ''no_snack5'' and pz.code = ''SHADES'' then 4::numeric\n               when public._v7_distribution_mode(p_promoter) = ''shades'' and pz.code = ''SNACK10'' then 70::numeric\n               when public._v7_distribution_mode(p_promoter) = ''shades'' and pz.code = ''SNACK5'' then 26::numeric\n               when public._v7_distribution_mode(p_promoter) = ''shades'' and pz.code = ''SHADES'' then 4::numeric\n               when public._v7_distribution_mode(p_promoter) = ''snacks'' and pz.code = ''SNACK10'' then 70::numeric\n               when public._v7_distribution_mode(p_promoter) = ''snacks'' and pz.code = ''SNACK5'' then 30::numeric\n               when public._v7_distribution_mode(p_promoter) is not null then 0::numeric\n               when v_special_campaign and v_shade_eligible then');
  d := replace(d,
    'and (not p_campaign.snack_launch_active or pz.code in (''SNACK5'',''SNACK10''))',
    'and (not p_campaign.snack_launch_active or pz.code in (''SNACK5'',''SNACK10'') or public._v7_distribution_mode(p_promoter) in (''shades'',''no_snack5''))');
  execute d;
end $$;

notify pgrst, 'reload schema';
