-- Blank optional search fields mean “not supplied”; only reject a field when
-- a non-empty normalized term has fewer than two searchable characters.
create or replace function public.search_authorized_outlets(
  p_outlet_name text default null, p_address text default null, p_license_no text default null,
  p_limit integer default 30, p_offset integer default 0)
returns table (
  id uuid, outlet_code text, name text, area text, city text, tse_id uuid, beat text,
  directory_record_id uuid, license_no text, address text, total_count bigint)
language plpgsql stable security definer set search_path = public as $$
declare v_name text := nullif(public.normalize_outlet_search_text(p_outlet_name), '');
  v_address text := nullif(public.normalize_outlet_search_text(p_address), '');
  v_license text := nullif(public.normalize_outlet_search_text(p_license_no), '');
  v_limit integer := greatest(1, least(coalesce(p_limit, 30), 50));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_name is null and v_address is null and v_license is null then
    raise exception 'SEARCH_TERM_REQUIRED';
  end if;
  if (v_name is not null and length(v_name) < 2)
     or (v_address is not null and length(v_address) < 2)
     or (v_license is not null and length(v_license) < 2) then
    raise exception 'SEARCH_TERM_TOO_SHORT';
  end if;

  return query
  with authorized as (
    select a.id, a.outlet_code, a.name, a.area, a.city, a.tse_id, a.beat,
      d.id as directory_record_id, d.license_no, d.address
    from public.get_promoter_outlets() a
    join public.outlets o on o.id = a.id
    left join public.tses t on t.id = o.tse_id
    left join public.territories tr on tr.id = t.territory_id
    left join public.states st on st.id = tr.state_id
    left join lateral (
      select m.id, m.license_no, m.address, m.normalized_license_no, m.normalized_address
        from public.outlet_search_master m
       where m.is_active and upper(st.code) = 'UP' and m.state_code = 'UP'
         and m.normalized_outlet_name = public.normalize_outlet_search_text(o.name)
       order by m.license_no nulls last, m.address nulls last, m.id
    ) d on true
    where (v_name is null or public.normalize_outlet_search_text(a.name) like '%' || v_name || '%'
       or public.normalize_outlet_search_text(a.outlet_code) like '%' || v_name || '%'
       or public.normalize_outlet_search_text(a.area) like '%' || v_name || '%'
       or public.normalize_outlet_search_text(a.city) like '%' || v_name || '%')
      and (v_address is null or d.normalized_address like '%' || v_address || '%')
      and (v_license is null or d.normalized_license_no like '%' || v_license || '%')
  )
  select a.id, a.outlet_code, a.name, a.area, a.city, a.tse_id, a.beat,
    a.directory_record_id, a.license_no, a.address, count(*) over ()
  from authorized a
  order by a.name, a.area nulls last, a.outlet_code, a.license_no nulls last, a.address nulls last
  limit v_limit offset v_offset;
end $$;

grant execute on function public.search_authorized_outlets(text, text, text, integer, integer) to authenticated;
notify pgrst, 'reload schema';
