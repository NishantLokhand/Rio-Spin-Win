-- Restore original report identities; expand only selected regional filters.
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

-- Preserve the shared date, staff, exclusion and transaction predicates.
-- A directory filter still matches its exact saved ID. A business region also
-- includes directory sales whose resolved city matches that region in its state.
do $$
declare predicate text; original text := 's.territory_id = ($1->>''territory_id'')::uuid';
begin
  predicate := public._sales_where();
  if position('regional_directory' in predicate)=0 then
    if position(original in predicate)=0 then raise exception 'TERRITORY_PREDICATE_NOT_FOUND'; end if;
    predicate := replace(predicate, original, $condition$(s.territory_id = ($1->>'territory_id')::uuid
      or exists (
        select 1 from public.territories regional_directory
        join public.territories selected_region on selected_region.id=($1->>'territory_id')::uuid
        where regional_directory.id=s.territory_id
          and regional_directory.code like 'GLOBAL-OUTLETS-%'
          and selected_region.code not like 'GLOBAL-OUTLETS-%'
          and regional_directory.state_id=s.state_id and selected_region.state_id=s.state_id
          and lower(btrim(selected_region.name)) = lower(btrim(regexp_replace(btrim(s.outlet_city), '\s+MKT$', '', 'i')))
      ))$condition$);
    execute format('create or replace function public._sales_where() returns text language sql immutable as %L',
      'select ' || quote_literal(predicate));
  end if;
end $$;
notify pgrst, 'reload schema';
