-- TUSHAR SURESH AMRUTKAR: standard V7, 95% INR10 / 5% INR5 without shades.
-- With available shades the existing rule becomes 90% INR10 / 6% INR5 / 4% shades.
-- Reported current stock: 25 INR5, 82 INR10, 3 speakers; never issue stock here.
-- Membership only: no inventory, allocator, V8 membership, toggle or date changes.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
select pg_advisory_xact_lock(hashtext('rio_tushar_v7_20261031'));

do $preflight$
begin
  if to_regclass('public.prize_user_distribution_overrides') is null
    or to_regclass('public.prize_v7_settings') is null
    or to_regprocedure('public._draw_prize_v7_20261029(public.campaigns,public.prize_configs,uuid,text)') is null
    or to_regprocedure('public._stock_problem_pre_v8_20261029(public.campaigns,public.prize_configs,uuid,text)') is null then
    raise exception 'Existing working V7/V8 installation is required; nothing changed';
  end if;
  if not exists(select 1 from pg_proc where oid=to_regprocedure('public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text)')
    and position('RIO_V8_DISPATCH_20261029' in prosrc)>0) then
    raise exception 'Expected existing V8 entry route preserving V7/V6; nothing changed';
  end if;
end $preflight$;

create table if not exists public.prize_tushar_v7_20261031_backup (
  target_key text primary key check(target_key='tushar_amrutkar'),
  user_id uuid not null unique, v7_before jsonb, v7_after jsonb not null,
  applied_at timestamptz not null default now(), rolled_back_at timestamptz
);
alter table public.prize_tushar_v7_20261031_backup enable row level security;
revoke all on public.prize_tushar_v7_20261031_backup from public,anon,authenticated;

do $enroll$
declare u record; v_id uuid; v_count integer:=0; c public.campaigns; cfg public.prize_configs;
  s public.prize_v7_settings; v_before jsonb; v_after jsonb; v_problem text;
  v_five integer; v_ten integer; v_shades integer;
begin
  if exists(select 1 from public.prize_tushar_v7_20261031_backup where target_key='tushar_amrutkar' and rolled_back_at is null) then
    if exists(select 1 from public.prize_tushar_v7_20261031_backup where target_key='tushar_amrutkar' and v7_after->>'mode'='no_snack5') then
      raise exception 'Earlier no-INR5 script was applied: run 20261031000100_restore_tushar_amrutkar_v7.sql first, then run this corrected script';
    end if;
    raise notice 'Enrollment already applied; later administrator changes preserved.';
    return;
  end if;
  for u in select a.id from public.app_users a
    where regexp_replace(upper(a.full_name),'[^A-Z0-9]','','g')='TUSHARSURESHAMRUTKAR'
    order by a.id for update
  loop v_count:=v_count+1; v_id:=u.id; end loop;
  if v_count<>1 then raise exception 'Expected exactly one TUSHAR SURESH AMRUTKAR account, found %; nothing changed',v_count; end if;
  if not exists(select 1 from public.app_users where id=v_id and is_active and role='promoter') then
    raise exception 'Tushar must be an active field account; nothing changed';
  end if;
  perform 1 from public.promoters where user_id=v_id for update;
  if not found then raise exception 'Tushar has no field inventory link; nothing changed'; end if;
  select * into c from public.campaigns where code='RSW-2026';
  select * into s from public.prize_v7_settings where campaign_id=c.id;
  if c.id is null or not c.track_inventory or s.campaign_id is null or not s.enabled
    or public.ist_today() not between s.starts_on and s.expires_on then
    raise exception 'V7 must already be active within its existing window; no toggle or expiry extension will be made';
  end if;
  -- Lock existing balances without changing stock. Never reissue the reported stock.
  perform 1 from public.promoter_inventory i join public.prizes p on p.id=i.prize_id
    where i.promoter_id=v_id and p.code in ('SNACK5','SNACK10','SHADES') order by i.prize_id for update of i;
  select coalesce(max(public._available(v_id,p.id)) filter(where p.code='SNACK5'),0),
    coalesce(max(public._available(v_id,p.id)) filter(where p.code='SNACK10'),0),
    coalesce(max(public._available(v_id,p.id)) filter(where p.code='SHADES'),0)
    into v_five,v_ten,v_shades from public.prizes p where p.is_active and p.code in ('SNACK5','SNACK10','SHADES');
  if v_five<=0 or v_ten<=0 then raise exception 'Tushar needs available INR5 AND INR10 stock; no stock issued'; end if;
  if v_five<>25 or v_ten<>82 then raise notice 'Reported INR5 25 / INR10 82; currently available INR5 % / INR10 %. Current stock retained.',v_five,v_ten; end if;
  select to_jsonb(o) into v_before from public.prize_user_distribution_overrides o where user_id=v_id for update;
  insert into public.prize_user_distribution_overrides as existing(user_id,mode,version,starts_on,expires_on,notes)
    values(v_id,'snacks',7,greatest(public.ist_today(),s.starts_on),s.expires_on,
      'TUSHAR SURESH AMRUTKAR: standard V7: 95% INR10 / 5% INR5 without shades; 90/6/4 with shades; reported 25 INR5, 82 INR10 and 3 speakers already stocked')
    on conflict(user_id) do update set mode=excluded.mode,version=excluded.version,starts_on=excluded.starts_on,
      expires_on=excluded.expires_on,notes=excluded.notes where existing.user_id=excluded.user_id;
  cfg:=public._active_config(c.id,null);
  v_problem:=public._stock_problem_pre_v8_20261029(c,cfg,v_id,c.id::text);
  if v_problem is not null then raise exception 'Existing ordinary stock readiness rejects Tushar: %; nothing changed',v_problem; end if;
  if public._v7_distribution_mode(v_id) is distinct from 'snacks' then raise exception 'V7 membership is not effective; nothing changed'; end if;
  select to_jsonb(o) into v_after from public.prize_user_distribution_overrides o where user_id=v_id;
  insert into public.prize_tushar_v7_20261031_backup as existing(target_key,user_id,v7_before,v7_after)
    values('tushar_amrutkar',v_id,v_before,v_after)
    on conflict(target_key) do update set user_id=excluded.user_id,v7_before=excluded.v7_before,v7_after=excluded.v7_after,
      applied_at=now(),rolled_back_at=null where existing.target_key=excluded.target_key and existing.rolled_back_at is not null;
end $enroll$;

select u.id as user_id,u.login_id,u.full_name,o.mode as v7_category,
  public._v7_distribution_mode(u.id) as effective_v7_category,o.starts_on,o.expires_on,
  public._available(u.id,p5.id) as snack5_available,public._available(u.id,p10.id) as snack10_available,
  public._available(u.id,ps.id) as shades_available,
  case when public._v7_distribution_mode(u.id) is null then 'V7 not effective'
    when public._available(u.id,ps.id)>0 then '90% INR10 / 6% INR5 / 4% shades'
    else '95% INR10 / 5% INR5' end as effective_ordinary_rule
from public.prize_tushar_v7_20261031_backup b join public.app_users u on u.id=b.user_id
left join public.prize_user_distribution_overrides o on o.user_id=u.id
join public.prizes p5 on p5.code='SNACK5' join public.prizes p10 on p10.code='SNACK10'
join public.prizes ps on ps.code='SHADES' where b.target_key='tushar_amrutkar';
commit;
