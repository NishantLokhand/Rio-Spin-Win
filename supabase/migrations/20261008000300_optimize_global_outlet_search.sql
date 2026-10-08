-- Keep global outlet search within the database statement timeout by using
-- trigram indexes to narrow directory candidates before calculating ranks.
do $$
declare v_opclass_schema text;
begin
  select ns.nspname into v_opclass_schema
  from pg_opclass oc join pg_am am on am.oid=oc.opcmethod
  join pg_namespace ns on ns.oid=oc.opcnamespace
  where oc.opcname='gin_trgm_ops' and am.amname='gin'
  order by (ns.nspname='extensions') desc limit 1;
  if v_opclass_schema is null then raise exception 'pg_trgm GIN operator class is unavailable'; end if;
  execute format('create index if not exists outlet_search_master_area_trgm_idx on public.outlet_search_master using gin (public.normalize_outlet_search_text(area) %I.gin_trgm_ops) where is_active',v_opclass_schema);
  execute format('create index if not exists outlet_search_master_route_trgm_idx on public.outlet_search_master using gin (public.normalize_outlet_search_text(route) %I.gin_trgm_ops) where is_active',v_opclass_schema);
  execute format('create index if not exists outlets_code_trgm_idx on public.outlets using gin (public.normalize_outlet_search_text(outlet_code) %I.gin_trgm_ops) where status=''active''',v_opclass_schema);
  execute format('create index if not exists outlets_city_trgm_idx on public.outlets using gin (public.normalize_outlet_search_text(city) %I.gin_trgm_ops) where status=''active''',v_opclass_schema);
end $$;

create or replace function public.search_authorized_outlets(p_outlet_name text default null,p_address text default null,
  p_license_no text default null,p_limit integer default 30,p_offset integer default 0)
returns table(id uuid,outlet_code text,name text,area text,city text,tse_id uuid,beat text,
  directory_record_id uuid,license_no text,address text,state_code text,match_tier text,total_count bigint)
language plpgsql stable security definer set search_path=public,extensions as $$
declare v_name text:=nullif(public.normalize_outlet_search_text(p_outlet_name),'');
  v_license text:=nullif(public.normalize_outlet_search_text(p_license_no),'');
  v_limit integer:=greatest(1,least(coalesce(p_limit,30),50)); v_offset integer:=greatest(0,coalesce(p_offset,0));
begin
  perform public._require_promoter();
  if v_name is null and v_license is null then raise exception 'SEARCH_TERM_REQUIRED'; end if;
  if (v_name is not null and length(v_name)<2) or (v_license is not null and length(v_license)<2) then raise exception 'SEARCH_TERM_TOO_SHORT'; end if;

  return query with candidate_directory_ids as (
    -- The imported directory has GIN indexes for normalized name/licence and
    -- this migration adds indexed area/route matching.
    select d.id
    from public.outlet_search_master d
    where d.is_active and d.operational_outlet_id is not null
      and (v_name is null or d.normalized_outlet_name=v_name
        or d.normalized_outlet_name like '%'||v_name||'%' or d.normalized_outlet_name % v_name
        or public.normalize_outlet_search_text(d.area) like '%'||v_name||'%'
        or public.normalize_outlet_search_text(d.area) % v_name
        or public.normalize_outlet_search_text(d.route) like '%'||v_name||'%'
        or public.normalize_outlet_search_text(d.route) % v_name)
      and (v_license is null or d.normalized_license_no=v_license
        or d.normalized_license_no like '%'||v_license||'%' or d.normalized_license_no % v_license)
    union
    -- Outlet code and city are operational fields rather than workbook fields.
    select d.id
    from public.outlets o
    join public.outlet_search_master d on d.operational_outlet_id=o.id and d.is_active
    where o.status='active' and d.operational_outlet_id is not null and v_name is not null
      and (public.normalize_outlet_search_text(o.outlet_code)=v_name
        or public.normalize_outlet_search_text(o.outlet_code) like '%'||v_name||'%'
        or public.normalize_outlet_search_text(o.outlet_code) % v_name
        or public.normalize_outlet_search_text(o.city) like '%'||v_name||'%'
        or public.normalize_outlet_search_text(o.city) % v_name)
      and (v_license is null or d.normalized_license_no=v_license
        or d.normalized_license_no like '%'||v_license||'%' or d.normalized_license_no % v_license)
  ), candidates as (
    select d.id directory_record_id,d.operational_outlet_id,o.outlet_code,o.name,
      coalesce(d.area,o.area) area,o.city,o.tse_id,coalesce(d.route,o.beat) beat,
      d.license_no,d.address,d.state_code,d.normalized_outlet_name,d.normalized_license_no,
      public.normalize_outlet_search_text(coalesce(d.area,o.area,'')) normalized_area,
      public.normalize_outlet_search_text(coalesce(d.route,o.beat,'')) normalized_route,
      d.imported_at
    from candidate_directory_ids ids
    join public.outlet_search_master d on d.id=ids.id
    join public.outlets o on o.id=d.operational_outlet_id and o.status='active'
  ), scored as (
    select c.*,case when v_name is null then 0 else greatest(
      case when c.normalized_outlet_name=v_name or public.normalize_outlet_search_text(c.outlet_code)=v_name then 1.0 else 0.0 end,
      case when c.normalized_outlet_name like '%'||v_name||'%'
        or public.normalize_outlet_search_text(c.outlet_code) like '%'||v_name||'%'
        or c.normalized_area like '%'||v_name||'%'
        or public.normalize_outlet_search_text(coalesce(c.city,'')) like '%'||v_name||'%'
        or c.normalized_route like '%'||v_name||'%' then 0.75 else 0.0 end,
      extensions.similarity(c.normalized_outlet_name,v_name),
      extensions.similarity(public.normalize_outlet_search_text(c.outlet_code),v_name),
      extensions.similarity(c.normalized_area,v_name),
      extensions.similarity(public.normalize_outlet_search_text(coalesce(c.city,'')),v_name),
      extensions.similarity(c.normalized_route,v_name)) end name_score,
      case when v_license is null then 0 else greatest(
        case when c.normalized_license_no=v_license then 1.0 else 0.0 end,
        case when c.normalized_license_no like '%'||v_license||'%' then 0.75 else 0.0 end,
        extensions.similarity(c.normalized_license_no,v_license)) end license_score
    from candidates c
  ), relevant as (
    select s.*,case when v_name is not null and v_license is not null then least(s.name_score,s.license_score)
      when v_name is not null then s.name_score else s.license_score end relevance
    from scored s
  ), deduplicated as (
    select r.*,row_number() over(partition by r.operational_outlet_id
      order by r.relevance desc,r.imported_at desc,r.directory_record_id) as outlet_rank
    from relevant r
  ), result_rows as (
    select d.* from deduplicated d where d.outlet_rank=1
  )
  select r.operational_outlet_id,r.outlet_code,r.name,r.area,r.city,r.tse_id,r.beat,
    r.directory_record_id,r.license_no,r.address,r.state_code,
    case when r.relevance>=0.999 then 'exact' when r.relevance>=0.5 then 'close' else 'broad' end,
    count(*) over()
  from result_rows r
  order by case when r.relevance>=0.999 then 0 when r.relevance>=0.5 then 1 else 2 end,
    r.relevance desc,r.name,r.area nulls last,r.outlet_code
  limit v_limit offset v_offset;
end $$;

revoke all on function public.search_authorized_outlets(text,text,text,integer,integer) from public,anon;
grant execute on function public.search_authorized_outlets(text,text,text,integer,integer) to authenticated;
notify pgrst,'reload schema';
