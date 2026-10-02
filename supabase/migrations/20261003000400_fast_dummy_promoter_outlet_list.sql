-- The disposable demo promoter has one manually assigned outlet and no
-- workbook map. Return that explicit assignment directly instead of evaluating
-- the legacy access predicate against the entire outlet directory.
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

  if v_person_id is null then return; end if;

  -- This special case is keyed by the seeded test promoter record, not by a
  -- general role or state. Its one existing manual assignment is authoritative.
  if v_designation='PROMOTER' and exists (
    select 1 from public.promoters pr
    where pr.user_id=auth.uid() and pr.promoter_code='TEST-9556600000'
  ) then
    return query
      select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
      from public.promoter_outlet_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active'
      where a.promoter_id=v_person_id and a.active
      order by o.name;
    return;
  end if;

  -- Maharashtra staff have explicit source-of-truth outlet maps. Avoid the
  -- older beat resolver, which evaluated every active outlet individually.
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

  -- Additive UP access is the union of manual assignments, workbook outlets,
  -- and outlets assigned to the promoter's MER. Resolve this set directly.
  if v_designation='PROMOTER'
    and v_access_mode='workbook_additive'
    and public.org_match_key(v_state) in ('up','uttarpradesh') then
    return query
      select distinct o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
      from public.outlets o
      where o.status='active'
        and (
          exists (
            select 1 from public.promoter_outlet_assignments a
            where a.promoter_id=v_person_id and a.outlet_id=o.id and a.active
          )
          or exists (
            select 1 from public.promoter_outlet_workbook_assignments a
            where a.promoter_id=v_person_id and a.outlet_id=o.id
              and public.org_match_key(a.source_state) in ('up','uttarpradesh')
          )
          or exists (
            select 1
            from (
              select a.mer_id from public.promoter_mer_assignments a
              where a.promoter_id=v_person_id
              union
              select p.mapped_mer_id from public.org_people p
              where p.id=v_person_id and p.mapped_mer_id is not null
            ) mapped
            join public.org_person_outlet_workbook_assignments a
              on a.person_id=mapped.mer_id and a.outlet_id=o.id
            where public.org_match_key(a.source_state) in ('up','uttarpradesh')
          )
        )
      order by o.name;
    return;
  end if;

  -- UP staff workbook rows are explicit and use the person-first primary key.
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

  -- Preserve all existing behavior for accounts other than the demo exception.
  return query
    select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
    from public.outlets o
    where o.status='active'
      and public.promoter_user_can_access_outlet(auth.uid(),o.id)
    order by o.name;
end $$;

revoke all on function public.get_promoter_outlets() from public,anon;
grant execute on function public.get_promoter_outlets() to authenticated;
