-- Enroll only the 2 requested existing field accounts in V8 (20 reported speakers).
-- Inventory was already issued. No inventory, V7 assignment, toggle or function is changed.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
-- Acquire before snapshot DDL so concurrent runs serialize before CREATE TABLE.
select pg_advisory_xact_lock(hashtext('rio_v8_ashish_sujal_20261031'));

do $preflight$
begin
  if to_regclass('public.prize_v8_users') is null or to_regclass('public.prize_v8_settings') is null then
    raise exception 'Install existing V8 first; no changes committed';
  end if;
  if not exists(select 1 from pg_proc where oid=to_regprocedure('public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text)')
    and position('RIO_V8_DISPATCH_20261029' in prosrc)>0) then
    raise exception 'Existing V8 dispatcher is missing; no changes committed';
  end if;
  if not exists(select 1 from public.campaigns c join public.prize_v8_settings s on s.campaign_id=c.id
    where c.code='RSW-2026' and c.track_inventory) then
    raise exception 'Existing inventory-tracked campaign/V8 settings are required';
  end if;
end $preflight$;

-- No foreign key: snapshots must not prevent later account deletion.
create table if not exists public.prize_v8_ashish_sujal_20261031_backup (
  target_no integer primary key check(target_no between 1 and 2),
  requested_name text not null, reported_qty integer not null,
  user_id uuid not null unique, v8_before jsonb, v8_after jsonb not null,
  applied_at timestamptz not null default now(), rolled_back_at timestamptz
);
alter table public.prize_v8_ashish_sujal_20261031_backup enable row level security;
revoke all on public.prize_v8_ashish_sujal_20261031_backup from public,anon,authenticated;

do $enroll$
declare r record; u record; v_id uuid; v_count integer; v_total integer;
  v_before jsonb; v_after jsonb; v_available integer; v_prize uuid;
begin
  select count(*) into v_total from public.prize_v8_ashish_sujal_20261031_backup;
  if v_total>0 then
    if v_total<>2 then raise exception 'Incomplete batch snapshot; inspect before proceeding'; end if;
    if not exists(select 1 from public.prize_v8_ashish_sujal_20261031_backup where rolled_back_at is not null) then
      raise notice 'Batch already applied. Later administrator edits preserved; no membership changes.';
      return;
    end if;
    if exists(select 1 from public.prize_v8_ashish_sujal_20261031_backup where rolled_back_at is null) then
      raise exception 'Partial rollback snapshot; inspect before proceeding';
    end if;
    delete from public.prize_v8_ashish_sujal_20261031_backup where rolled_back_at is not null;
  end if;
  select id into v_prize from public.prizes where code='SPEAKER' and is_active;
  if v_prize is null then raise exception 'Active SPEAKER catalogue entry required'; end if;
  for r in select * from (values
    (1,'ASHISH RAMU KALWAL',10),
    (2,'SUJAL KALIDAS WANKHEDE',10)
  ) x(target_no,requested_name,reported_qty) order by target_no loop
    v_id:=null; v_count:=0;
    -- Count ALL exact normalized names before validating the role. Never resolve
    -- an ambiguous identity by filtering out inactive or differently linked rows.
    for u in select a.id,a.role,a.is_active from public.app_users a
      where regexp_replace(upper(a.full_name),'[^A-Z0-9]','','g')=
        regexp_replace(upper(r.requested_name),'[^A-Z0-9]','','g')
      order by a.id for update
    loop
      v_count:=v_count+1; v_id:=u.id;
    end loop;
    if v_count<>1 then raise exception 'Expected exactly one account for %, found %; entire batch aborted',r.requested_name,v_count; end if;
    if not exists(select 1 from public.app_users where id=v_id and role='promoter' and is_active) then
      raise exception '% is not an active field account; entire batch aborted',r.requested_name;
    end if;
    perform 1 from public.promoters where user_id=v_id for update;
    if not found then raise exception '% has no field inventory link',r.requested_name; end if;
    select i.on_hand-i.reserved into v_available from public.promoter_inventory i
      where i.promoter_id=v_id and i.prize_id=v_prize for update;
    if coalesce(v_available,0)<=0 then raise exception '% has no available speaker stock; no stock will be issued',r.requested_name; end if;
    if v_available<>r.reported_qty then
      raise notice '%: reported %, currently available %. Existing balances retained (may reflect live activity).',r.requested_name,r.reported_qty,v_available;
    end if;
    select to_jsonb(m) into v_before from public.prize_v8_users m where m.user_id=v_id for update;
    insert into public.prize_v8_users as existing(user_id,reported_speakers,enabled)
      values(v_id,r.reported_qty,true)
    on conflict(user_id) do update set reported_speakers=excluded.reported_speakers,enabled=true
      where existing.user_id=excluded.user_id;
    select to_jsonb(m) into v_after from public.prize_v8_users m where m.user_id=v_id;
    insert into public.prize_v8_ashish_sujal_20261031_backup(target_no,requested_name,reported_qty,user_id,v8_before,v8_after)
      values(r.target_no,r.requested_name,r.reported_qty,v_id,v_before,v_after);
  end loop;
  raise notice '2 accounts enrolled; 20 speakers recorded as reference only. Stock, ordinary rules, global toggles and history retained.';
end $enroll$;

-- Review these 2 results. A false v8_effective means existing toggle/date settings
-- or a later account change prevent V8; enrollment does not override those choices.
select b.target_no,b.requested_name,u.id as user_id,u.login_id,u.full_name,
  m.reported_speakers,m.enabled as selected_for_v8,public._v8_user_enabled(c.id,u.id) as v8_effective,
  public._v7_distribution_mode(u.id) as ordinary_v7_category,
  i.on_hand as speakers_in_stock,i.reserved as speakers_reserved,i.on_hand-i.reserved as speakers_available,
  (select count(*) from public.spins sp where sp.promoter_id=u.id and sp.campaign_id=c.id and sp.biz_date=public.ist_today()) as spins_today
from public.prize_v8_ashish_sujal_20261031_backup b
join public.app_users u on u.id=b.user_id
left join public.prize_v8_users m on m.user_id=u.id
join public.campaigns c on c.code='RSW-2026'
join public.prizes p on p.code='SPEAKER'
left join public.promoter_inventory i on i.promoter_id=u.id and i.prize_id=p.id
order by b.target_no;
commit;
