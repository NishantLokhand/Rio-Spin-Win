-- Let promoters access outlets covered by their mapped MER(s).
-- UP source rows are associated by exact normalized market + area. Outlets are
-- associated to a MER by exact normalized beat matching. Maharashtra remains
-- unmapped until its promoter/MER mapping is supplied or an admin maps it.

create table if not exists public.promoter_mer_assignments (
  promoter_id uuid not null references public.org_people(id) on delete cascade,
  mer_id uuid not null references public.org_people(id) on delete cascade,
  assignment_source text not null check (assignment_source in ('manual','source_area_match')),
  assigned_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (promoter_id, mer_id),
  check (promoter_id <> mer_id)
);
create index if not exists promoter_mer_assignments_mer_idx on public.promoter_mer_assignments(mer_id);
alter table public.promoter_mer_assignments enable row level security;
drop policy if exists promoter_mer_assignments_admin_all on public.promoter_mer_assignments;
create policy promoter_mer_assignments_admin_all on public.promoter_mer_assignments
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.promoter_mer_assignments from anon;
grant select on public.promoter_mer_assignments to authenticated;

create or replace function public.org_match_key(p_value text)
returns text language sql immutable parallel safe set search_path=public as $$
  select regexp_replace(lower(replace(trim(coalesce(p_value,'')), chr(160), ' ')), '[^a-z0-9]', '', 'g')
$$;

create or replace function public.refresh_up_mer_matches(p_market text, p_area text)
returns void language plpgsql security definer set search_path=public as $$
declare v_market text:=public.org_match_key(p_market); v_area text:=public.org_match_key(p_area);
begin
  if v_market='' or v_area='' then return; end if;
  delete from public.promoter_mer_assignments a using public.org_people p
    where a.promoter_id=p.id and a.assignment_source='source_area_match'
      and p.source_system='UP_TSE_MER_PROMO_AREAS' and p.designation='PROMOTER'
      and public.org_match_key(p.market_raw)=v_market and public.org_match_key(p.area_raw)=v_area;
  insert into public.promoter_mer_assignments(promoter_id,mer_id,assignment_source)
  select p.id,m.id,'source_area_match'
  from public.org_people p join public.org_people m
    on m.designation='MER' and m.source_system='UP_TSE_MER_PROMO_AREAS'
   and public.org_match_key(m.market_raw)=v_market and public.org_match_key(m.area_raw)=v_area
  where p.designation='PROMOTER' and p.source_system='UP_TSE_MER_PROMO_AREAS'
    and public.org_match_key(p.market_raw)=v_market and public.org_match_key(p.area_raw)=v_area
  on conflict (promoter_id,mer_id) do nothing;
end $$;

create or replace function public.sync_up_mer_matches_trigger()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    if new.source_system='UP_TSE_MER_PROMO_AREAS' and new.designation in ('PROMOTER','MER') then
      perform public.refresh_up_mer_matches(new.market_raw,new.area_raw);
    end if;
  elsif tg_op='DELETE' then
    if old.source_system='UP_TSE_MER_PROMO_AREAS' and old.designation in ('PROMOTER','MER') then
      perform public.refresh_up_mer_matches(old.market_raw,old.area_raw);
    end if;
    return old;
  else
    if old.source_system='UP_TSE_MER_PROMO_AREAS' and old.designation in ('PROMOTER','MER') then
      perform public.refresh_up_mer_matches(old.market_raw,old.area_raw);
    end if;
    if new.source_system='UP_TSE_MER_PROMO_AREAS' and new.designation in ('PROMOTER','MER') then
      perform public.refresh_up_mer_matches(new.market_raw,new.area_raw);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists org_people_sync_up_mer_matches on public.org_people;
create trigger org_people_sync_up_mer_matches after insert or update of designation,source_system,market_raw,area_raw or delete
  on public.org_people for each row execute function public.sync_up_mer_matches_trigger();

-- Preserve any existing single-MER admin links in the new many-to-many model.
insert into public.promoter_mer_assignments(promoter_id,mer_id,assignment_source)
select p.id,p.mapped_mer_id,'manual' from public.org_people p
join public.org_people m on m.id=p.mapped_mer_id and m.designation='MER'
where p.designation='PROMOTER'
on conflict (promoter_id,mer_id) do nothing;
update public.org_people set mapped_mer_id=null where designation='PROMOTER' and mapped_mer_id is not null;

-- Backfill UP relationships, including multiple MERs sharing an exact market/area.
do $$ declare r record; begin
  for r in select distinct market_raw,area_raw from public.org_people
    where source_system='UP_TSE_MER_PROMO_AREAS' and designation in ('PROMOTER','MER') loop
    perform public.refresh_up_mer_matches(r.market_raw,r.area_raw);
  end loop;
end $$;

create or replace function public.set_promoter_mers(p_promoter_id uuid,p_mer_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_mer uuid;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if not exists(select 1 from public.org_people where id=p_promoter_id and designation='PROMOTER') then raise exception 'PROMOTER_NOT_FOUND'; end if;
  foreach v_mer in array coalesce(p_mer_ids,'{}'::uuid[]) loop
    if not exists(select 1 from public.org_people where id=v_mer and designation='MER' and active) then raise exception 'MER_NOT_FOUND'; end if;
  end loop;
  delete from public.promoter_mer_assignments where promoter_id=p_promoter_id and assignment_source='manual'
    and not (mer_id=any(coalesce(p_mer_ids,'{}'::uuid[])));
  insert into public.promoter_mer_assignments(promoter_id,mer_id,assignment_source,assigned_by)
    select p_promoter_id,x,'manual',auth.uid() from unnest(coalesce(p_mer_ids,'{}'::uuid[])) x
    where not exists(select 1 from public.promoter_mer_assignments a where a.promoter_id=p_promoter_id and a.mer_id=x and a.assignment_source='source_area_match')
    on conflict (promoter_id,mer_id) do update set assignment_source='manual',assigned_by=excluded.assigned_by,created_at=now();
  return jsonb_build_object('assigned',coalesce(cardinality(p_mer_ids),0));
end $$;

create or replace function public.promoter_user_can_access_outlet(p_user_id uuid,p_outlet_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
begin
  if not public.is_admin() and p_user_id is distinct from auth.uid()
    and not exists(select 1 from public.promoters pr where pr.user_id=p_user_id and pr.supervisor_id=auth.uid()) then
    return false;
  end if;
  return exists(
    select 1 from public.org_people p join public.outlets o on o.id=p_outlet_id and o.status='active'
    where p.auth_user_id=p_user_id and p.designation='PROMOTER' and p.active
      and (
        exists(select 1 from public.promoter_outlet_assignments a where a.promoter_id=p.id and a.outlet_id=o.id and a.active)
        or exists(
          select 1 from (
            select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=p.id
            union select p.mapped_mer_id where p.mapped_mer_id is not null
          ) mapped join public.org_people m on m.id=mapped.mer_id and m.designation='MER' and m.active
          cross join lateral jsonb_array_elements_text(coalesce(m.beat_override,m.beat_values,'[]'::jsonb)) beat(value)
          where public.org_match_key(beat.value)=public.org_match_key(o.beat) and public.org_match_key(o.beat)<>''
        )
      )
  );
end $$;

drop policy if exists outlets_read on public.outlets;
create policy outlets_read on public.outlets for select to authenticated using (
  public.is_admin()
  or (public.my_role()='promoter' and public.promoter_user_can_access_outlet(auth.uid(),outlets.id))
  or (public.my_role()='supervisor' and exists(select 1 from public.promoters pr
    where pr.supervisor_id=auth.uid() and public.promoter_user_can_access_outlet(pr.user_id,outlets.id)))
);

drop policy if exists tses_read on public.tses;
create policy tses_read on public.tses for select to authenticated using (
  public.is_admin()
  or (public.my_role()='promoter' and exists(select 1 from public.outlets o where o.tse_id=tses.id and public.promoter_user_can_access_outlet(auth.uid(),o.id)))
  or (public.my_role()='supervisor' and exists(select 1 from public.promoters pr join public.outlets o on true
    where pr.supervisor_id=auth.uid() and o.tse_id=tses.id and public.promoter_user_can_access_outlet(pr.user_id,o.id)))
);

create or replace function public.get_promoter_outlets()
returns table(id uuid,outlet_code text,name text,area text,city text,tse_id uuid,beat text)
language plpgsql stable security definer set search_path=public as $$
begin
  perform public._require_promoter();
  return query select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
    from public.outlets o where o.status='active' and public.promoter_user_can_access_outlet(auth.uid(),o.id)
    order by o.name;
end $$;

create or replace function public.snapshot_org_assignment_on_sale()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_person uuid; v_mer_names text;
begin
  select id into v_person from public.org_people p where p.auth_user_id=new.promoter_id and p.designation='PROMOTER' and p.active;
  if v_person is null then raise exception 'ORG_PROFILE_MISSING' using hint='Ask an administrator to link your organizational promoter record.'; end if;
  if not public.promoter_user_can_access_outlet(new.promoter_id,new.outlet_id) then
    raise exception 'OUTLET_NOT_ASSIGNED' using hint='This promoter is not assigned to the selected outlet or its mapped MER.';
  end if;
  select string_agg(distinct m.employee_name,', ' order by m.employee_name) into v_mer_names
    from (select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=v_person
      union select p.mapped_mer_id from public.org_people p where p.id=v_person and p.mapped_mer_id is not null) mapped
    join public.org_people m on m.id=mapped.mer_id and m.designation='MER';
  select coalesce(p.market_override,p.market_raw),coalesce(p.area_override,p.area_raw),coalesce(p.beat_override->>0,p.beat_values->>0),t.employee_name,v_mer_names,o.beat
    into new.promoter_market_snapshot,new.promoter_area_snapshot,new.promoter_beat_snapshot,new.promoter_tse_snapshot,new.promoter_mer_snapshot,new.outlet_beat_snapshot
    from public.org_people p left join public.org_people t on t.id=p.mapped_tse_id left join public.outlets o on o.id=new.outlet_id
    where p.auth_user_id=new.promoter_id;
  return new;
end $$;
drop trigger if exists sales_org_assignment_snapshot on public.sales;
create trigger sales_org_assignment_snapshot before insert on public.sales for each row execute function public.snapshot_org_assignment_on_sale();

create or replace function public.validate_promoter_session_outlet()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.org_people p where p.auth_user_id=new.promoter_id and p.designation='PROMOTER' and p.active) then
    raise exception 'ORG_PROFILE_MISSING' using hint='Ask an administrator to link your organizational promoter record.';
  end if;
  if not public.promoter_user_can_access_outlet(new.promoter_id,new.outlet_id) then
    raise exception 'OUTLET_NOT_ASSIGNED' using hint='This promoter is not assigned to the selected outlet or its mapped MER.';
  end if;
  return new;
end $$;
drop trigger if exists promoter_session_outlet_access on public.promoter_sessions;
create trigger promoter_session_outlet_access before insert or update of outlet_id on public.promoter_sessions for each row execute function public.validate_promoter_session_outlet();

revoke all on function public.org_match_key(text), public.refresh_up_mer_matches(text,text), public.sync_up_mer_matches_trigger(), public.promoter_user_can_access_outlet(uuid,uuid), public.set_promoter_mers(uuid,uuid[]), public.get_promoter_outlets() from public,anon;
grant execute on function public.promoter_user_can_access_outlet(uuid,uuid), public.set_promoter_mers(uuid,uuid[]), public.get_promoter_outlets() to authenticated;
