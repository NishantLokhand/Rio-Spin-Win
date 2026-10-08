-- Repair global search metadata projection. Safe to run after the initial
-- global outlet import; does not modify outlets, assignments, or sale history.
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
  return query with candidates as (
    select o.id,o.outlet_code,o.name,coalesce(d.area,o.area) area,o.city,o.tse_id,coalesce(d.route,o.beat) beat,
      d.id directory_record_id,d.license_no,d.address,d.state_code,
      case when v_name is null then 0 else greatest(
        case when public.normalize_outlet_search_text(o.name)=v_name or public.normalize_outlet_search_text(o.outlet_code)=v_name then 1.0 else 0.0 end,
        case when position(v_name in public.normalize_outlet_search_text(o.name))>0
          or position(v_name in public.normalize_outlet_search_text(o.outlet_code))>0
          or position(v_name in public.normalize_outlet_search_text(coalesce(d.area,o.area,'')))>0
          or position(v_name in public.normalize_outlet_search_text(coalesce(o.city,'')))>0
          or position(v_name in public.normalize_outlet_search_text(coalesce(d.route,o.beat,'')))>0 then 0.75 else 0.0 end,
        extensions.similarity(public.normalize_outlet_search_text(o.name),v_name),
        extensions.similarity(public.normalize_outlet_search_text(o.outlet_code),v_name),
        extensions.similarity(public.normalize_outlet_search_text(coalesce(d.area,o.area,'')),v_name),
        extensions.similarity(public.normalize_outlet_search_text(coalesce(o.city,'')),v_name),
        extensions.similarity(public.normalize_outlet_search_text(coalesce(d.route,o.beat,'')),v_name)) end name_score,
      case when v_license is null then 0 else greatest(
        case when d.normalized_license_no=v_license then 1.0 else 0.0 end,
        case when position(v_license in coalesce(d.normalized_license_no,''))>0 then 0.75 else 0.0 end,
        extensions.similarity(d.normalized_license_no,v_license)) end license_score
    from public.outlets o
    left join lateral (
      select m.id,m.license_no,m.address,m.normalized_license_no,m.area,m.route,m.state_code
      from public.outlet_search_master m
      where m.is_active and m.operational_outlet_id=o.id
      order by m.imported_at desc,m.id limit 1
    ) d on true
    where o.status='active'
      and (v_name is null or public.normalize_outlet_search_text(o.name)=v_name
        or public.normalize_outlet_search_text(o.outlet_code)=v_name
        or position(v_name in public.normalize_outlet_search_text(o.name))>0
        or position(v_name in public.normalize_outlet_search_text(o.outlet_code))>0
        or position(v_name in public.normalize_outlet_search_text(coalesce(d.area,o.area,'')))>0
        or position(v_name in public.normalize_outlet_search_text(coalesce(o.city,'')))>0
        or position(v_name in public.normalize_outlet_search_text(coalesce(d.route,o.beat,'')))>0
        or extensions.similarity(public.normalize_outlet_search_text(o.name),v_name)>=0.12
        or extensions.similarity(public.normalize_outlet_search_text(o.outlet_code),v_name)>=0.12
        or extensions.similarity(public.normalize_outlet_search_text(coalesce(d.area,o.area,'')),v_name)>=0.12
        or extensions.similarity(public.normalize_outlet_search_text(coalesce(o.city,'')),v_name)>=0.12
        or extensions.similarity(public.normalize_outlet_search_text(coalesce(d.route,o.beat,'')),v_name)>=0.12)
      and (v_license is null or position(v_license in coalesce(d.normalized_license_no,''))>0
        or extensions.similarity(d.normalized_license_no,v_license)>=0.12)
  ), scored as (
    select c.*,case when v_name is not null and v_license is not null then least(c.name_score,c.license_score)
      when v_name is not null then c.name_score else c.license_score end relevance
    from candidates c
  )
  select c.id,c.outlet_code,c.name,c.area,c.city,c.tse_id,c.beat,c.directory_record_id,c.license_no,c.address,c.state_code,
    case when c.relevance>=0.999 then 'exact' when c.relevance>=0.5 then 'close' else 'broad' end,
    count(*) over()
  from scored c
  order by case when c.relevance>=0.999 then 0 when c.relevance>=0.5 then 1 else 2 end,
    c.relevance desc,c.name,c.area nulls last,c.outlet_code
  limit v_limit offset v_offset;
end $$;

revoke all on function public.search_authorized_outlets(text,text,text,integer,integer) from public,anon;
grant execute on function public.search_authorized_outlets(text,text,text,integer,integer) to authenticated;
notify pgrst,'reload schema';
