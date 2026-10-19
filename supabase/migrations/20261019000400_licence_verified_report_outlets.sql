-- Licence numbers are reused across markets. Confirm a specific directory ID
-- and its licence; never resolve by name or licence number alone.
create table if not exists public.outlet_identity_links (
  legacy_outlet_id uuid primary key references public.outlets(id),
  directory_record_id uuid not null references public.outlet_search_master(id),
  verified_licence text not null,
  verified_by uuid references public.app_users(id),
  verified_at timestamptz not null default now()
);
alter table public.outlet_identity_links enable row level security;
revoke all on public.outlet_identity_links from public,anon,authenticated;

create or replace function public.confirm_outlet_identity(p_legacy uuid,p_directory uuid,p_licence text)
returns void language plpgsql security definer set search_path=public as $$
declare d public.outlet_search_master; o public.outlets; state_code text;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  select * into o from public.outlets where id=p_legacy for update;
  select * into d from public.outlet_search_master where id=p_directory and is_active;
  if o.id is null or d.id is null or d.operational_outlet_id is null then raise exception 'OUTLET_NOT_FOUND'; end if;
  if nullif(btrim(p_licence),'') is null or public.normalize_outlet_search_text(p_licence) in ('0','na','none')
    or public.normalize_outlet_search_text(p_licence) is distinct from public.normalize_outlet_search_text(d.license_no)
    then raise exception 'LICENCE_CONFIRMATION_MISMATCH'; end if;
  select code into state_code from public.states where id=o.state_id;
  if state_code is distinct from d.state_code then raise exception 'OUTLET_STATE_MISMATCH'; end if;
  if o.id=d.operational_outlet_id then raise exception 'OUTLET_ALREADY_CANONICAL'; end if;
  if exists(select 1 from public.outlet_identity_links where legacy_outlet_id=d.operational_outlet_id)
    then raise exception 'OUTLET_IDENTITY_CHAIN_NOT_ALLOWED'; end if;
  insert into public.outlet_identity_links(legacy_outlet_id,directory_record_id,verified_licence,verified_by)
    values(o.id,d.id,d.license_no,auth.uid()) on conflict(legacy_outlet_id) do update set
    directory_record_id=excluded.directory_record_id,verified_licence=excluded.verified_licence,
    verified_by=excluded.verified_by,verified_at=now();
  -- Retain the old record and all sale/spin foreign keys; hide the duplicate
  -- from new selections. Historical reports resolve through the verified link.
  update public.outlets set status='inactive',updated_at=now() where id=o.id;
  perform public.write_audit('OUTLET_LICENCE_IDENTITY_CONFIRMED','outlets',o.id::text,
    jsonb_build_object('directory_record_id',d.id,'canonical_outlet_id',d.operational_outlet_id,'licence',d.license_no));
end $$;
revoke all on function public.confirm_outlet_identity(uuid,uuid,text) from public,anon;
grant execute on function public.confirm_outlet_identity(uuid,uuid,text) to authenticated;

-- Preserve immutable sale snapshots. Resolve presentation and geography before
-- filtering/grouping so UI, CSV, Excel and all report tabs use the same identity.
do $$
declare columns_sql text;
begin
  select string_agg(case a.attname
    when 'outlet_id' then 'coalesce(d.operational_outlet_id,s.outlet_id) as outlet_id'
    when 'outlet_name' then 'coalesce(d.outlet_name,s.outlet_name) as outlet_name'
    when 'outlet_code' then 'coalesce(o.outlet_code,s.outlet_code) as outlet_code'
    when 'outlet_city' then 'coalesce(nullif(d.city,''''),s.outlet_city) as outlet_city'
    when 'outlet_area' then 'coalesce(nullif(d.area,''''),s.outlet_area) as outlet_area'
    else format('s.%I',a.attname) end,', ' order by a.attnum) into columns_sql
  from pg_attribute a where a.attrelid='public.sales'::regclass and a.attnum>0 and not a.attisdropped;
  execute 'create or replace view public.report_sales_resolved with (security_invoker=true) as select '||columns_sql||'
    from public.sales s
    left join public.outlet_identity_links link on link.legacy_outlet_id=s.outlet_id
    left join public.states st on st.id=s.state_id
    left join public.outlet_search_master d on d.id=coalesce(link.directory_record_id,s.outlet_search_master_id)
      and d.state_code=st.code and d.operational_outlet_id is not null
      and ((link.legacy_outlet_id is not null and public.normalize_outlet_search_text(link.verified_licence)=d.normalized_license_no)
        or (link.legacy_outlet_id is null and d.operational_outlet_id=s.outlet_id
          and nullif(btrim(s.outlet_license_no),'''') is not null
          and public.normalize_outlet_search_text(s.outlet_license_no)=d.normalized_license_no))
    left join public.outlets o on o.id=d.operational_outlet_id';
end $$;
revoke all on public.report_sales_resolved from public,anon,authenticated;

do $$
declare r record; definition text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('report_summary','report_user_performance','report_user_daily',
      'prize_distribution_report','get_report_cities','get_report_areas')
  loop
    definition:=pg_get_functiondef(r.oid);
    definition:=replace(definition,'public.sales s','public.report_sales_resolved s');
    execute definition;
  end loop;
end $$;
notify pgrst,'reload schema';
