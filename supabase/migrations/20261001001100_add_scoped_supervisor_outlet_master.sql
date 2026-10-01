-- Return only the supervisor's reachable outlet set in one scoped query.
-- This avoids scanning the entire outlets table through a row-by-row RLS
-- predicate when staff pages initialize.
create or replace function public.get_supervisor_outlet_master()
returns table (
  id uuid,
  outlet_code text,
  name text,
  area text,
  city text,
  beat text,
  distributor text,
  tse_id uuid,
  status text,
  source text,
  external_ref text,
  tse_code text,
  tse_name text,
  territory_id uuid
)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.my_role() is distinct from 'supervisor'::public.user_role then
    raise exception 'SUPERVISOR_ONLY';
  end if;

  return query
  with supervised_people as (
    select p.id,p.outlet_access_mode,p.mapped_mer_id
    from public.promoters pr
    join public.org_people p on p.auth_user_id=pr.user_id
      and p.designation='PROMOTER' and p.active
    where pr.supervisor_id=auth.uid()
  ), mapped_mer as (
    select sp.id as promoter_id,a.mer_id
    from supervised_people sp
    join public.promoter_mer_assignments a on a.promoter_id=sp.id
    union
    select sp.id,sp.mapped_mer_id
    from supervised_people sp where sp.mapped_mer_id is not null
  ), authorized_outlet_ids as (
    select a.outlet_id
    from supervised_people sp
    join public.promoter_outlet_assignments a on a.promoter_id=sp.id and a.active
    where sp.outlet_access_mode is distinct from 'workbook_exact'
    union
    select a.outlet_id
    from supervised_people sp
    join public.promoter_outlet_workbook_assignments a on a.promoter_id=sp.id
      and a.source_state='UTTAR PRADESH'
    where sp.outlet_access_mode in ('workbook_exact','workbook_additive')
    union
    select o.id
    from supervised_people sp
    join mapped_mer mm on mm.promoter_id=sp.id
    join public.org_people m on m.id=mm.mer_id and m.designation='MER' and m.active
    cross join lateral jsonb_array_elements_text(
      coalesce(m.beat_override,m.beat_values,'[]'::jsonb)
    ) beat(value)
    join public.outlets o on o.status='active'
      and public.org_match_key(beat.value)=public.org_match_key(o.beat)
      and public.org_match_key(o.beat)<>''
    where sp.outlet_access_mode is distinct from 'workbook_exact'
  )
  select o.id,o.outlet_code,o.name,o.area,o.city,o.beat,o.distributor,o.tse_id,
         o.status::text,o.source::text,o.external_ref,t.code,t.name,t.territory_id
  from (select distinct outlet_id from authorized_outlet_ids) allowed
  join public.outlets o on o.id=allowed.outlet_id and o.status='active'
  left join public.tses t on t.id=o.tse_id and t.status='active'
  order by o.name;
end $$;

revoke all on function public.get_supervisor_outlet_master() from public,anon;
grant execute on function public.get_supervisor_outlet_master() to authenticated;
