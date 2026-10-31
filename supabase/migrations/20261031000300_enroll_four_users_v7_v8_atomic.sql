-- RUN THIS COMPLETE FILE ONCE instead of the earlier individual enrollment files.
-- Membership only: no function replacement, inventory issue, toggle/date change,
-- allocator/counter reset, daily-award reset, account creation or history deletion.
-- Tushar: standard V7. Ashish/Sujal/Harshraj: existing V8 speaker membership.
begin;
set local lock_timeout='5s';
set local statement_timeout='45s';
select pg_advisory_xact_lock(hashtext('rio_four_users_20261031'));
-- Serialize with the older individual scripts if one is run concurrently.
select pg_advisory_xact_lock(hashtext('rio_tushar_v7_20261031'));
select pg_advisory_xact_lock(hashtext('rio_v8_ashish_sujal_20261031'));
select pg_advisory_xact_lock(hashtext('rio_v8_harshraj_20261030'));

do $preflight$
begin
  if to_regclass('public.prize_user_distribution_overrides') is null
     or to_regclass('public.prize_v7_settings') is null
     or to_regclass('public.prize_v8_users') is null
     or to_regclass('public.prize_v8_settings') is null
     or to_regprocedure('public._v7_distribution_mode(uuid)') is null
     or to_regprocedure('public._v8_user_enabled(uuid,uuid)') is null
     or to_regprocedure('public._draw_prize_v7_20261029(public.campaigns,public.prize_configs,uuid,text)') is null
     or to_regprocedure('public._stock_problem_pre_v8_20261029(public.campaigns,public.prize_configs,uuid,text)') is null then
    raise exception 'Existing working V7/V8 installation is required; nothing changed';
  end if;
  if not exists(select 1 from pg_proc p
      where p.oid=to_regprocedure('public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text)')
        and position('RIO_V8_DISPATCH_20261029' in p.prosrc)>0)
     or not exists(select 1 from pg_proc p
      where p.oid=to_regprocedure('public._stock_problem(public.campaigns,public.prize_configs,uuid,text)')
        and position('RIO_V8_STOCK_GATE_20261029' in p.prosrc)>0) then
    raise exception 'Expected existing working V8 routes missing; nothing changed. Do not reinstall allocators to force this script';
  end if;
end $preflight$;

-- Private rollback snapshot, deliberately without account foreign keys.
create table if not exists public.prize_four_users_20261031_backup (
  target_no integer primary key check(target_no between 1 and 4),
  requested_name text not null, user_id uuid not null unique,
  v7_before jsonb, v7_after jsonb, v8_before jsonb, v8_after jsonb,
  v7_changed boolean not null, v8_changed boolean not null,
  applied_at timestamptz not null default now(), rolled_back_at timestamptz
);
alter table public.prize_four_users_20261031_backup enable row level security;
revoke all on public.prize_four_users_20261031_backup from public,anon,authenticated;

do $enroll$
declare
  r record; u record; v_id uuid; v_count integer; v_total integer;
  c public.campaigns; s7 public.prize_v7_settings; s8 public.prize_v8_settings;
  cfg public.prize_configs; v_before7 jsonb; v_after7 jsonb;
  v_before8 jsonb; v_after8 jsonb; v_problem text;
  v_five integer; v_ten integer; v_speakers integer;
begin
  select count(*) into v_total from public.prize_four_users_20261031_backup;
  if v_total>0 then
    if v_total<>4 then raise exception 'Incomplete four-user snapshot; nothing changed'; end if;
    if not exists(select 1 from public.prize_four_users_20261031_backup where rolled_back_at is not null) then
      raise notice 'This combined enrollment was already applied. Later administrator membership edits are preserved; review the four status rows below.';
      return;
    end if;
    if exists(select 1 from public.prize_four_users_20261031_backup where rolled_back_at is null) then
      raise exception 'Partial rollback snapshot; nothing changed';
    end if;
    delete from public.prize_four_users_20261031_backup where rolled_back_at is not null;
  end if;

  select * into c from public.campaigns where code='RSW-2026' for share;
  select * into s7 from public.prize_v7_settings where campaign_id=c.id for share;
  select * into s8 from public.prize_v8_settings where campaign_id=c.id for share;
  if c.id is null or not c.track_inventory or c.snack_launch_active
     or s7.campaign_id is null or not s7.enabled
     or public.ist_today() not between s7.starts_on and s7.expires_on
     or s8.campaign_id is null or not s8.enabled
     or public.ist_today()<s8.starts_on
     or (s8.expires_on is not null and public.ist_today()>s8.expires_on) then
    raise exception 'RSW-2026 must already have inventory tracking, launch phase off and effective V7/V8 settings; no toggle/date was changed';
  end if;
  cfg:=public._active_config(c.id,null);
  if cfg.id is null then raise exception 'Existing active prize configuration required; nothing changed'; end if;
  if (select count(*) from public.prizes where is_active and code in('SNACK5','SNACK10','SHADES','SPEAKER'))<>4 then
    raise exception 'Existing active snack, shade and speaker catalogue entries required; nothing changed';
  end if;

  for r in select * from (values
    (1,'TUSHAR SURESH AMRUTKAR',3),
    (2,'ASHISH RAMU KALWAL',10),
    (3,'SUJAL KALIDAS WANKHEDE',10),
    (4,'HARSHRAJ SHELAR',20)
  ) requested(target_no,requested_name,reported_speakers) order by target_no loop
    v_id:=null; v_count:=0;
    -- Count all exact normalized names before checking role/activity.
    for u in select a.id from public.app_users a
      where regexp_replace(upper(a.full_name),'[^A-Z0-9]','','g')=
        regexp_replace(upper(r.requested_name),'[^A-Z0-9]','','g')
      order by a.id for update
    loop v_id:=u.id; v_count:=v_count+1; end loop;
    if v_count<>1 then
      raise exception 'Expected exactly one account for %, found %; all four updates aborted',r.requested_name,v_count;
    end if;
    if not exists(select 1 from public.app_users where id=v_id and role='promoter' and is_active) then
      raise exception '% must be an active field account; all four updates aborted',r.requested_name;
    end if;
    perform 1 from public.promoters where user_id=v_id for update;
    if not found then raise exception '% has no field inventory link; all four updates aborted',r.requested_name; end if;
    if not exists(select 1 from public.org_people where auth_user_id=v_id and active) then
      raise exception '% has no active organizational profile; all four updates aborted',r.requested_name;
    end if;
    perform 1 from public.promoter_inventory i join public.prizes p on p.id=i.prize_id
      where i.promoter_id=v_id and p.code in('SNACK5','SNACK10','SHADES','SPEAKER')
      order by i.prize_id for update of i;
    select coalesce(max(public._available(v_id,p.id)) filter(where p.code='SNACK5'),0),
      coalesce(max(public._available(v_id,p.id)) filter(where p.code='SNACK10'),0),
      coalesce(max(public._available(v_id,p.id)) filter(where p.code='SPEAKER'),0)
      into v_five,v_ten,v_speakers from public.prizes p where p.is_active;
    select to_jsonb(o) into v_before7 from public.prize_user_distribution_overrides o where o.user_id=v_id for update;
    select to_jsonb(m) into v_before8 from public.prize_v8_users m where m.user_id=v_id for update;

    if r.target_no=1 then
      if v_five<=0 or v_ten<=0 then raise exception 'Tushar needs available INR5 AND INR10 stock; all four updates aborted'; end if;
      if v_five<>25 or v_ten<>82 or v_speakers<>3 then
        raise notice 'Tushar reported 25 INR5 / 82 INR10 / 3 speakers; current available % / % / %. Current inventory retained.',v_five,v_ten,v_speakers;
      end if;
      -- Correct even an earlier no-INR5 enrollment; snapshot its actual prior row.
      -- Keep an already-effective standard V7 row byte-for-byte unchanged.
      if public._v7_distribution_mode(v_id) is distinct from 'snacks' then
        insert into public.prize_user_distribution_overrides as existing(user_id,mode,version,starts_on,expires_on,notes)
          values(v_id,'snacks',7,greatest(public.ist_today(),s7.starts_on),s7.expires_on,
            'TUSHAR SURESH AMRUTKAR: standard V7; 95/5 without shades, 90/6/4 with shades; stock already entered by administrator')
        on conflict(user_id) do update set mode=excluded.mode,version=excluded.version,starts_on=excluded.starts_on,
          expires_on=excluded.expires_on,notes=excluded.notes where existing.user_id=excluded.user_id;
      end if;
      if public._v7_distribution_mode(v_id) is distinct from 'snacks' then raise exception 'Tushar V7 enrollment not effective; all four updates aborted'; end if;
    else
      if v_speakers<=0 then raise exception '% has no available speaker stock; all four updates aborted',r.requested_name; end if;
      if v_speakers<>r.reported_speakers then
        raise notice '% reported % speakers, currently available %. Current inventory retained.',r.requested_name,r.reported_speakers,v_speakers;
      end if;
      -- Already-selected users (including Harshraj) retain their exact row.
      if not coalesce((v_before8->>'enabled')::boolean,false) then
        insert into public.prize_v8_users as existing(user_id,reported_speakers,enabled)
          values(v_id,r.reported_speakers,true)
        on conflict(user_id) do update set reported_speakers=excluded.reported_speakers,enabled=true
          where existing.user_id=excluded.user_id;
      end if;
      if not coalesce(public._v8_user_enabled(c.id,v_id),false) then raise exception '% V8 enrollment not effective; all four updates aborted',r.requested_name; end if;
    end if;
    v_problem:=public._stock_problem_pre_v8_20261029(c,cfg,v_id,c.id::text);
    if v_problem is not null then
      raise exception 'Existing ordinary-spin stock readiness rejects %: %; no allocator changed; all four updates aborted',r.requested_name,v_problem;
    end if;
    select to_jsonb(o) into v_after7 from public.prize_user_distribution_overrides o where o.user_id=v_id;
    select to_jsonb(m) into v_after8 from public.prize_v8_users m where m.user_id=v_id;
    insert into public.prize_four_users_20261031_backup
      (target_no,requested_name,user_id,v7_before,v7_after,v8_before,v8_after,v7_changed,v8_changed)
      values(r.target_no,r.requested_name,v_id,v_before7,v_after7,v_before8,v_after8,
        v_before7 is distinct from v_after7,v_before8 is distinct from v_after8);
  end loop;
end $enroll$;

-- Four confirmation rows: Harshraj's existing membership and current stock shown.
select b.requested_name,u.id as user_id,u.login_id,u.is_active,
  b.v7_changed,b.v8_changed,public._v7_distribution_mode(u.id) as effective_v7_category,
  o.expires_on as v7_expires_on,m.enabled as selected_for_v8,
  public._v8_user_enabled(c.id,u.id) as v8_effective,m.reported_speakers,
  coalesce((select public._available(u.id,p.id) from public.prizes p where p.code='SNACK5'),0) as snack5_available,
  coalesce((select public._available(u.id,p.id) from public.prizes p where p.code='SNACK10'),0) as snack10_available,
  coalesce((select public._available(u.id,p.id) from public.prizes p where p.code='SHADES'),0) as shades_available,
  coalesce((select public._available(u.id,p.id) from public.prizes p where p.code='SPEAKER'),0) as speakers_available,
  (select count(*) from public.spins sp where sp.promoter_id=u.id and sp.campaign_id=c.id and sp.biz_date=public.ist_today()) as spins_today
from public.prize_four_users_20261031_backup b join public.app_users u on u.id=b.user_id
join public.campaigns c on c.code='RSW-2026'
left join public.prize_user_distribution_overrides o on o.user_id=u.id
left join public.prize_v8_users m on m.user_id=u.id
order by b.target_no;
commit;
