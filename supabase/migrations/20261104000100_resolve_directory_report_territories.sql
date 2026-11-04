-- Directory imports use a technical territory, not the outlet's business market.
-- Resolve only that technical territory using the licence-verified report city.
-- Keep explicit territories, immutable sale snapshots and ambiguous markets intact.
do $$
declare definition text; columns_sql text;
begin
  definition := rtrim(pg_get_viewdef('public.report_sales_resolved'::regclass, true), E';\n\r ');
  select string_agg(case a.attname
    when 'territory_id' then 'coalesce(m.id,r.territory_id) as territory_id'
    when 'territory_name' then 'coalesce(m.name,r.territory_name) as territory_name'
    else format('r.%I',a.attname) end, ', ' order by a.attnum)
    into columns_sql
    from pg_attribute a where a.attrelid='public.report_sales_resolved'::regclass
      and a.attnum>0 and not a.attisdropped;
  execute 'create or replace view public.report_sales_resolved with (security_invoker=true) as
    with resolved as (' || definition || ')
    select ' || columns_sql || ' from resolved r
    left join public.territories technical on technical.id=r.territory_id
    left join lateral (
      select (array_agg(t.id))[1] as id, min(t.name) as name
      from public.territories t
      where technical.code like ''GLOBAL-OUTLETS-%''
        and technical.state_id=r.state_id and t.state_id=r.state_id
        and t.code not like ''GLOBAL-OUTLETS-%''
        and lower(btrim(t.name)) = lower(btrim(regexp_replace(btrim(r.outlet_city), ''\s+MKT$'', '''', ''i'')))
      having count(*)=1
    ) m on true';
end $$;
notify pgrst, 'reload schema';
