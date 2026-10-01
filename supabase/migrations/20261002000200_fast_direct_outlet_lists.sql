-- Return explicit workbook access directly for the common UP flow.
-- The previous function evaluated the access predicate against every active
-- outlet, even when the user had a small, explicit assignment list.
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

  -- Exact UP promoter lists are authoritative. Join the assignment table by
  -- its person-first primary key instead of testing every active outlet.
  if v_person_id is not null and v_designation='PROMOTER'
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

  -- UP staff workbook rows are likewise explicit. Keep Maharashtra and
  -- legacy identity/route access on the existing policy path below.
  if v_person_id is not null and v_designation in ('MER','TSE')
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
