-- Allow app-role promoter logins backed by MER/TSE org records to use assigned
-- outlets. Normal PROMOTER authorization and snapshot behavior is unchanged.

create or replace function public.snapshot_org_assignment_on_sale()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_person uuid; v_mer_names text;
begin
  select id into v_person from public.org_people p
    where p.auth_user_id=new.promoter_id and p.active
      and p.designation in ('PROMOTER','MER','TSE');
  if v_person is null then
    raise exception 'ORG_PROFILE_MISSING' using hint='Ask an administrator to link your organizational profile.';
  end if;
  if not public.promoter_user_can_access_outlet(new.promoter_id,new.outlet_id) then
    raise exception 'OUTLET_NOT_ASSIGNED' using hint='This account is not assigned to the selected outlet.';
  end if;
  select string_agg(distinct m.employee_name,', ' order by m.employee_name) into v_mer_names
    from (select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=v_person
      union select p.mapped_mer_id from public.org_people p where p.id=v_person and p.mapped_mer_id is not null) mapped
    join public.org_people m on m.id=mapped.mer_id and m.designation='MER';
  select coalesce(p.market_override,p.market_raw),coalesce(p.area_override,p.area_raw),
    coalesce(p.beat_override->>0,p.beat_values->>0),t.employee_name,v_mer_names,o.beat
    into new.promoter_market_snapshot,new.promoter_area_snapshot,new.promoter_beat_snapshot,
      new.promoter_tse_snapshot,new.promoter_mer_snapshot,new.outlet_beat_snapshot
    from public.org_people p
    left join public.org_people t on t.id=p.mapped_tse_id
    left join public.outlets o on o.id=new.outlet_id
    where p.id=v_person;
  return new;
end $$;

create or replace function public.validate_promoter_session_outlet()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.org_people p
    where p.auth_user_id=new.promoter_id and p.active
      and p.designation in ('PROMOTER','MER','TSE')) then
    raise exception 'ORG_PROFILE_MISSING' using hint='Ask an administrator to link your organizational profile.';
  end if;
  if not public.promoter_user_can_access_outlet(new.promoter_id,new.outlet_id) then
    raise exception 'OUTLET_NOT_ASSIGNED' using hint='This account is not assigned to the selected outlet.';
  end if;
  return new;
end $$;

-- A partially resolved staff list may safely add only unique outlet matches.
-- Keep its previous access until the entire uploaded list resolves; a complete
-- import continues to replace the employee's list exactly.
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
  v_people_partial integer := 0;
  v_people_preserved integer := 0;
  v_assignment_count integer := 0;
  v_accounts_linked integer := 0;
  v_rows_affected integer := 0;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if length(coalesce(p_run_key,'')) < 8 then raise exception 'IMPORT_RUN_KEY_REQUIRED'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'STAFF_OUTLET_IMPORT_INVALID'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    if coalesce(r->>'designation','') not in ('TSE','MER')
      or nullif(r->>'employee_name','') is null
      or nullif(r->>'market_raw','') is null
      or nullif(r->>'area_raw','') is null
      or jsonb_typeof(r->'outlet_ids') is distinct from 'array'
      or coalesce((r->>'expected_count')::integer,0) < 1
      or coalesce((r->>'unresolved_count')::integer,0) < 0
      or (jsonb_array_length(r->'outlet_ids')=0 and coalesce((r->>'unresolved_count')::integer,0)=0) then
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
      and p.designation=(r->>'designation')
      and public.org_match_key(p.employee_name)=public.org_match_key(r->>'employee_name')
      and public.org_match_key(p.state_raw) in ('uttarpradesh','up')
      and public.org_match_key(p.market_raw)=public.org_match_key(r->>'market_raw')
      and public.org_match_key(p.area_raw)=public.org_match_key(r->>'area_raw');

    if coalesce(v_person_count,0)<>1 then
      v_people_preserved := v_people_preserved+1;
      continue;
    end if;
    v_person := v_person_ids[1];

    -- Link only a uniquely matching existing promoter-app login and never
    -- steal a login already linked to another organizational profile.
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
    ) and not exists(select 1 from public.org_people linked where linked.auth_user_id=au.id and linked.id<>v_person);
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
      ) and not exists(select 1 from public.org_people linked where linked.auth_user_id=au.id and linked.id<>v_person);
      v_user_count := coalesce(array_length(v_user_ids,1),0);
    end if;
    if v_user_count=1 then
      v_user := v_user_ids[1];
      update public.org_people set auth_user_id=v_user,updated_at=now()
        where id=v_person and auth_user_id is null;
      if found then v_accounts_linked := v_accounts_linked+1; end if;
    end if;

    if coalesce((r->>'unresolved_count')::integer,0)>0 then
      for v_outlet in select distinct value::uuid from jsonb_array_elements_text(r->'outlet_ids') ids(value)
      loop
        insert into public.org_person_outlet_workbook_assignments(person_id,outlet_id,source_state,source_run_key)
        values(v_person,v_outlet,'UTTAR PRADESH',p_run_key)
        on conflict(person_id,outlet_id,source_state) do update
          set source_run_key=excluded.source_run_key,imported_at=now();
        get diagnostics v_rows_affected = row_count;
        v_assignment_count := v_assignment_count+v_rows_affected;
      end loop;
      v_people_partial := v_people_partial+1;
      continue;
    end if;

    delete from public.org_person_outlet_workbook_assignments
      where person_id=v_person and source_state='UTTAR PRADESH';
    for v_outlet in select distinct value::uuid from jsonb_array_elements_text(r->'outlet_ids') ids(value)
    loop
      insert into public.org_person_outlet_workbook_assignments(person_id,outlet_id,source_state,source_run_key)
      values(v_person,v_outlet,'UTTAR PRADESH',p_run_key)
      on conflict(person_id,outlet_id,source_state) do update
        set source_run_key=excluded.source_run_key,imported_at=now();
      v_assignment_count := v_assignment_count+1;
    end loop;
    v_people_updated := v_people_updated+1;
  end loop;

  perform public.write_audit('UP_TSE_MER_OUTLET_ACCESS_IMPORTED',
    'org_person_outlet_workbook_assignments',p_run_key,
    jsonb_build_object('employees_updated',v_people_updated,'employees_partial',v_people_partial,
      'employees_preserved',v_people_preserved,'assignments',v_assignment_count,'accounts_linked',v_accounts_linked));
  return jsonb_build_object('employees_updated',v_people_updated,'employees_partial',v_people_partial,
    'employees_preserved',v_people_preserved,'assignments',v_assignment_count,'accounts_linked',v_accounts_linked);
end $$;

revoke all on function public.import_up_tse_mer_outlet_access(text,jsonb) from public,anon;
grant execute on function public.import_up_tse_mer_outlet_access(text,jsonb) to authenticated;
