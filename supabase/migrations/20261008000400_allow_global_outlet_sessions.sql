-- Global outlet access: selecting an active outlet must not depend on legacy
-- promoter/TSE/MER outlet assignments. Keep the linked active org profile
-- checks and preserve the assignment snapshots recorded on new sales.

create or replace function public.validate_promoter_session_outlet()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if not exists (
    select 1
    from public.org_people p
    where p.auth_user_id=new.promoter_id
      and p.active
      and p.designation in ('PROMOTER','MER','TSE')
  ) then
    raise exception 'ORG_PROFILE_MISSING'
      using hint='Ask an administrator to link your organizational profile.';
  end if;

  if not exists (
    select 1 from public.outlets o
    where o.id=new.outlet_id and o.status='active'
  ) then
    raise exception 'OUTLET_INACTIVE';
  end if;

  return new;
end;
$$;

create or replace function public.snapshot_org_assignment_on_sale()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_person uuid;
  v_mer_names text;
begin
  select p.id into v_person
  from public.org_people p
  where p.auth_user_id=new.promoter_id
    and p.active
    and p.designation in ('PROMOTER','MER','TSE');

  if v_person is null then
    raise exception 'ORG_PROFILE_MISSING'
      using hint='Ask an administrator to link your organizational profile.';
  end if;

  if not exists (
    select 1 from public.outlets o
    where o.id=new.outlet_id and o.status='active'
  ) then
    raise exception 'OUTLET_INACTIVE';
  end if;

  select string_agg(distinct m.employee_name,', ' order by m.employee_name)
  into v_mer_names
  from (
    select a.mer_id
    from public.promoter_mer_assignments a
    where a.promoter_id=v_person
    union
    select p.mapped_mer_id
    from public.org_people p
    where p.id=v_person and p.mapped_mer_id is not null
  ) mapped
  join public.org_people m on m.id=mapped.mer_id and m.designation='MER';

  select coalesce(p.market_override,p.market_raw),
    coalesce(p.area_override,p.area_raw),
    coalesce(p.beat_override->>0,p.beat_values->>0),
    t.employee_name,v_mer_names,o.beat
  into new.promoter_market_snapshot,new.promoter_area_snapshot,
    new.promoter_beat_snapshot,new.promoter_tse_snapshot,
    new.promoter_mer_snapshot,new.outlet_beat_snapshot
  from public.org_people p
  left join public.org_people t on t.id=p.mapped_tse_id
  left join public.outlets o on o.id=new.outlet_id
  where p.id=v_person;

  return new;
end;
$$;

comment on function public.validate_promoter_session_outlet() is
  'Global outlet access: require a linked active field profile and active outlet, not a legacy outlet assignment.';
comment on function public.snapshot_org_assignment_on_sale() is
  'Global outlet access: snapshot organizational labels for any active outlet without enforcing legacy outlet assignments.';
