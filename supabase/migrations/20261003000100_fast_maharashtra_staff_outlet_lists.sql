-- Use the explicit source-of-truth outlet map for Maharashtra staff accounts.
-- The old regional fallback tested every active outlet with a per-outlet
-- access function, which becomes too slow after the Maharashtra outlet import.
create or replace function public.get_promoter_outlets()
returns table(id uuid,outlet_code text,name text,area text,city text,tse_id uuid,beat text)
language plpgsql stable security definer set search_path=public as $$
declare
  v_person_id uuid;
  v_designation text;
  v_state text;
  v_access_mode text;
begin
  perform public._require_promoter();

  select p.id,p.designation,p.state_raw,p.outlet_access_mode
    into v_person_id,v_designation,v_state,v_access_mode
  from public.org_people p
  where p.auth_user_id=auth.uid() and p.active
    and p.designation in ('PROMOTER','MER','TSE');

  -- Unlinked logins have no organizational outlet scope. Avoid scanning the
  -- entire outlet directory through promoter_user_can_access_outlet().
  if v_person_id is null then return; end if;

  -- Maharashtra TSE/MER access is explicit in the source-of-truth workbook.
  -- Return those assignments directly; an empty source map means no listed
  -- outlets and should also return quickly without a directory-wide scan.
  if v_designation in ('MER','TSE')
    and public.org_match_key(v_state) in ('mh','maharashtra','maharashtrarom') then
    return query
      select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
      from public.org_person_outlet_workbook_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active'
      where a.person_id=v_person_id
        and public.org_match_key(a.source_state) in ('mh','maharashtra','maharashtrarom')
      order by o.name;
    return;
  end if;

  -- Exact UP promoter lists are authoritative.
  if v_designation='PROMOTER'
    and v_access_mode='workbook_exact'
    and public.org_match_key(v_state) in ('up','uttarpradesh') then
    return query
      select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
      from public.promoter_outlet_workbook_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active'
      where a.promoter_id=v_person_id
        and public.org_match_key(a.source_state) in ('up','uttarpradesh')
      order by o.name;
    return;
  end if;

  -- UP staff workbook rows are likewise explicit.
  if v_designation in ('MER','TSE')
    and public.org_match_key(v_state) in ('up','uttarpradesh')
    and exists (
      select 1 from public.org_person_outlet_workbook_assignments a
      where a.person_id=v_person_id
        and public.org_match_key(a.source_state) in ('up','uttarpradesh')
    ) then
    return query
      select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
      from public.org_person_outlet_workbook_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active'
      where a.person_id=v_person_id
        and public.org_match_key(a.source_state) in ('up','uttarpradesh')
      order by o.name;
    return;
  end if;

  return query
    select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
    from public.outlets o
    where o.status='active'
      and public.promoter_user_can_access_outlet(auth.uid(),o.id)
    order by o.name;
end $$;

revoke all on function public.get_promoter_outlets() from public,anon;
grant execute on function public.get_promoter_outlets() to authenticated;
