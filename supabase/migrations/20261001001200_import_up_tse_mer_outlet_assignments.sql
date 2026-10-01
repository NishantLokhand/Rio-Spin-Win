-- Store explicit UP workbook outlet access for organizational TSEs and MERs.
-- This is separate from outlets.tse_id and promoter access, so shared outlets
-- do not overwrite their existing ownership or promoter assignments.
create table if not exists public.org_person_outlet_workbook_assignments (
  person_id uuid not null references public.org_people(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  source_state text not null,
  source_run_key text not null,
  imported_at timestamptz not null default now(),
  primary key (person_id,outlet_id,source_state)
);
create index if not exists org_person_outlet_workbook_outlet_idx
  on public.org_person_outlet_workbook_assignments(outlet_id,source_state);
alter table public.org_person_outlet_workbook_assignments enable row level security;
drop policy if exists org_person_outlet_workbook_admin_read on public.org_person_outlet_workbook_assignments;
create policy org_person_outlet_workbook_admin_read
  on public.org_person_outlet_workbook_assignments for select to authenticated
  using (public.is_admin());
revoke all on public.org_person_outlet_workbook_assignments from anon;
grant select on public.org_person_outlet_workbook_assignments to authenticated;

create or replace function public.import_up_tse_mer_outlet_access(
  p_run_key text,
  p_rows jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r jsonb;
  v_person_ids uuid[];
  v_person uuid;
  v_person_count integer;
  v_outlet uuid;
  v_user_ids uuid[];
  v_user uuid;
  v_user_count integer;
  v_people_updated integer := 0;
  v_people_preserved integer := 0;
  v_assignment_count integer := 0;
  v_accounts_linked integer := 0;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if length(coalesce(p_run_key,'')) < 8 then raise exception 'IMPORT_RUN_KEY_REQUIRED'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'STAFF_OUTLET_IMPORT_INVALID'; end if;

  -- Validate all outlet IDs before replacing any employee's prior UP list.
  for r in select value from jsonb_array_elements(p_rows) loop
    if coalesce(r->>'designation','') not in ('TSE','MER')
      or nullif(r->>'employee_name','') is null
      or nullif(r->>'market_raw','') is null
      or nullif(r->>'area_raw','') is null
      or jsonb_typeof(r->'outlet_ids') is distinct from 'array'
      or coalesce((r->>'unresolved_count')::integer,0) < 0 then
      raise exception 'STAFF_OUTLET_IMPORT_INVALID';
    end if;
    if exists (
      select 1 from jsonb_array_elements_text(r->'outlet_ids') ids(value)
      left join public.outlets o on o.id=ids.value::uuid and o.status='active'
      where o.id is null
    ) then raise exception 'STAFF_OUTLET_TARGET_INVALID'; end if;
  end loop;

  for r in select value from jsonb_array_elements(p_rows) loop
    select array_agg(p.id),count(*) into v_person_ids,v_person_count
    from public.org_people p
    where p.active and p.source_system='UP_TSE_MER_PROMO_AREAS'
      and p.designation=r->>'designation'
      and public.org_match_key(p.employee_name)=public.org_match_key(r->>'employee_name')
      and public.org_match_key(p.state_raw) in ('uttarpradesh','up')
      and public.org_match_key(p.market_raw)=public.org_match_key(r->>'market_raw')
      and public.org_match_key(p.area_raw)=public.org_match_key(r->>'area_raw');

    if coalesce(v_person_count,0)<>1 then
      -- Keep prior mappings when the source employee identity is not unique.
      v_people_preserved := v_people_preserved+1;
      continue;
    end if;

    v_person := v_person_ids[1];
    -- TSE/MER login accounts keep app role "promoter". Link their org profile
    -- from the reconciled employee inventory by unique phone, then unique name.
    select array_agg(distinct au.id) into v_user_ids
    from public.org_inventory i
    join public.app_users au on au.role='promoter'
      and nullif(regexp_replace(coalesce(i.mobile,''),'\D','','g'),'') is not null
      and regexp_replace(coalesce(au.mobile,au.login_id,''),'\D','','g')=regexp_replace(i.mobile,'\D','','g')
    join public.promoters pr on pr.user_id=au.id
    where i.designation=v_person.designation and (
      i.person_id=v_person or (i.person_id is null
        and public.org_match_key(i.employee_name)=public.org_match_key(v_person.employee_name)
        and public.org_match_key(i.state_raw) in ('uttarpradesh','up')
        and public.org_match_key(i.market_raw)=public.org_match_key(v_person.market_raw)
        and public.org_match_key(i.area_raw)=public.org_match_key(v_person.area_raw))
    )
      and not exists(select 1 from public.org_people linked where linked.auth_user_id=au.id and linked.id<>v_person);
    v_user_count := coalesce(array_length(v_user_ids,1),0);
    if v_user_count=0 then
      select array_agg(distinct au.id) into v_user_ids
      from public.org_inventory i
      join public.app_users au on au.role='promoter'
        and lower(regexp_replace(trim(au.full_name),'\s+',' ','g'))=lower(regexp_replace(trim(i.employee_name),'\s+',' ','g'))
      join public.promoters pr on pr.user_id=au.id
      where i.designation=v_person.designation and (
        i.person_id=v_person or (i.person_id is null
          and public.org_match_key(i.employee_name)=public.org_match_key(v_person.employee_name)
          and public.org_match_key(i.state_raw) in ('uttarpradesh','up')
          and public.org_match_key(i.market_raw)=public.org_match_key(v_person.market_raw)
          and public.org_match_key(i.area_raw)=public.org_match_key(v_person.area_raw))
      )
        and not exists(select 1 from public.org_people linked where linked.auth_user_id=au.id and linked.id<>v_person);
      v_user_count := coalesce(array_length(v_user_ids,1),0);
    end if;
    if v_user_count=1 then
      v_user := v_user_ids[1];
      update public.org_people set auth_user_id=v_user,updated_at=now()
        where id=v_person and auth_user_id is null;
      if found then v_accounts_linked := v_accounts_linked+1; end if;
    end if;

    if coalesce((r->>'unresolved_count')::integer,0)>0 then
      v_people_preserved := v_people_preserved+1;
      continue;
    end if;

    delete from public.org_person_outlet_workbook_assignments
      where person_id=v_person and source_state='UTTAR PRADESH';
    for v_outlet in
      select distinct value::uuid from jsonb_array_elements_text(r->'outlet_ids') ids(value)
    loop
      insert into public.org_person_outlet_workbook_assignments(
        person_id,outlet_id,source_state,source_run_key
      ) values(v_person,v_outlet,'UTTAR PRADESH',p_run_key)
      on conflict(person_id,outlet_id,source_state) do update
        set source_run_key=excluded.source_run_key,imported_at=now();
      v_assignment_count := v_assignment_count+1;
    end loop;
    v_people_updated := v_people_updated+1;
  end loop;

  perform public.write_audit('UP_TSE_MER_OUTLET_ACCESS_IMPORTED',
    'org_person_outlet_workbook_assignments',p_run_key,
    jsonb_build_object('employees_updated',v_people_updated,'employees_preserved',v_people_preserved,
      'assignments',v_assignment_count,'accounts_linked',v_accounts_linked));
  return jsonb_build_object('employees_updated',v_people_updated,
    'employees_preserved',v_people_preserved,'assignments',v_assignment_count,
    'accounts_linked',v_accounts_linked);
end $$;

-- Keep the established master, inventory and promoter import atomic with the
-- new staff outlet map.
create or replace function public.import_org_master_inventory_with_staff_outlets(
  p_master jsonb,
  p_inventory jsonb,
  p_run_key text,
  p_promoter_outlet_rows jsonb,
  p_promoter_outlet_mode text,
  p_promoter_unresolved_count integer,
  p_staff_outlet_rows jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_result jsonb;
  v_staff_result jsonb;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  v_result := public.import_org_master_inventory_with_promoter_outlets(
    p_master,p_inventory,p_run_key,p_promoter_outlet_rows,
    p_promoter_outlet_mode,p_promoter_unresolved_count
  );
  v_staff_result := public.import_up_tse_mer_outlet_access(p_run_key,p_staff_outlet_rows);
  return v_result || jsonb_build_object('staff_outlet_access',v_staff_result);
end $$;

-- The promoter RPC is also used for TSE/MER logins (their app role remains
-- promoter). Keep legacy beat/identity visibility and add the explicit UP map.
create or replace function public.promoter_user_can_access_outlet(p_user_id uuid,p_outlet_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_mode text; v_person public.org_people;
begin
  if not public.is_admin() and p_user_id is distinct from auth.uid()
    and not exists(select 1 from public.promoters pr where pr.user_id=p_user_id and pr.supervisor_id=auth.uid()) then
    return false;
  end if;
  select p.* into v_person from public.org_people p
    where p.auth_user_id=p_user_id and p.active and p.designation in ('PROMOTER','MER','TSE');
  if v_person.id is null then return false; end if;

  if v_person.designation='MER' then
    return exists(select 1 from public.org_person_outlet_workbook_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active'
      where a.person_id=v_person.id and a.source_state='UTTAR PRADESH' and o.id=p_outlet_id)
      or exists(
        select 1 from public.outlets o
        cross join lateral jsonb_array_elements_text(coalesce(v_person.beat_override,v_person.beat_values,'[]'::jsonb)) b(value)
        where o.id=p_outlet_id and o.status='active'
          and public.org_match_key(b.value)=public.org_match_key(o.beat)
          and public.org_match_key(o.beat)<>''
      );
  elsif v_person.designation='TSE' then
    return exists(select 1 from public.org_person_outlet_workbook_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active'
      where a.person_id=v_person.id and a.source_state='UTTAR PRADESH' and o.id=p_outlet_id)
      or exists(
        select 1 from public.outlets o join public.tses t on t.id=o.tse_id
        where o.id=p_outlet_id and o.status='active'
          and (
            (nullif(regexp_replace(coalesce(v_person.mobile,''),'\D','','g'),'') is not null
              and regexp_replace(coalesce(t.mobile,''),'\D','','g')=regexp_replace(v_person.mobile,'\D','','g')
              and (select count(*) from public.tses tm where regexp_replace(coalesce(tm.mobile,''),'\D','','g')=regexp_replace(v_person.mobile,'\D','','g'))=1)
            or (nullif(v_person.fas_id,'') is not null and t.external_ref=v_person.fas_id
              and (select count(*) from public.tses te where te.external_ref=v_person.fas_id)=1)
            or (nullif(v_person.qa_employee_id,'') is not null and t.external_ref=v_person.qa_employee_id
              and (select count(*) from public.tses te where te.external_ref=v_person.qa_employee_id)=1)
            or (nullif(regexp_replace(lower(trim(v_person.employee_name)),'\s+','','g'),'') is not null
              and regexp_replace(lower(trim(t.name)),'\s+','','g')=regexp_replace(lower(trim(v_person.employee_name)),'\s+','','g')
              and (select count(*) from public.tses tn where regexp_replace(lower(trim(tn.name)),'\s+','','g')=regexp_replace(lower(trim(v_person.employee_name)),'\s+','','g'))=1)
          )
      );
  end if;

  select p.outlet_access_mode into v_mode from public.org_people p
    where p.id=v_person.id and p.designation='PROMOTER';
  if v_mode is null then return false; end if;
  if v_mode='workbook_exact' then
    return exists(select 1 from public.promoter_outlet_workbook_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active'
      where a.promoter_id=v_person.id and a.source_state='UTTAR PRADESH' and o.id=p_outlet_id);
  end if;
  return exists(select 1 from public.outlets o where o.id=p_outlet_id and o.status='active' and (
    exists(select 1 from public.promoter_outlet_assignments a where a.promoter_id=v_person.id and a.outlet_id=o.id and a.active)
    or (v_mode='workbook_additive' and exists(select 1 from public.promoter_outlet_workbook_assignments a where a.promoter_id=v_person.id and a.outlet_id=o.id and a.source_state='UTTAR PRADESH'))
    or exists(select 1 from (
      select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=v_person.id
      union select v_person.mapped_mer_id where v_person.mapped_mer_id is not null
    ) mapped join public.org_people m on m.id=mapped.mer_id and m.designation='MER' and m.active
      cross join lateral jsonb_array_elements_text(coalesce(m.beat_override,m.beat_values,'[]'::jsonb)) beat(value)
      where public.org_match_key(beat.value)=public.org_match_key(o.beat) and public.org_match_key(o.beat)<>''
    )
  ));
end $$;

revoke all on function public.import_up_tse_mer_outlet_access(text,jsonb) from public,anon;
grant execute on function public.import_up_tse_mer_outlet_access(text,jsonb) to authenticated;
revoke all on function public.import_org_master_inventory_with_staff_outlets(jsonb,jsonb,text,jsonb,text,integer,jsonb) from public,anon;
grant execute on function public.import_org_master_inventory_with_staff_outlets(jsonb,jsonb,text,jsonb,text,integer,jsonb) to authenticated;
revoke all on function public.promoter_user_can_access_outlet(uuid,uuid) from public,anon;
grant execute on function public.promoter_user_can_access_outlet(uuid,uuid) to authenticated;
