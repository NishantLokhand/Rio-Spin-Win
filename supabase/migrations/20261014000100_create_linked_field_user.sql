-- Complete the database portion of field-user onboarding in one transaction.
-- Authentication is created by admin-users, which deletes that new identity if
-- this RPC fails. Only the service role may supply an actor and a new auth ID.
create or replace function public.create_linked_field_user(
  p_actor uuid, p_user_id uuid, p_login text, p_name text, p_mobile text,
  p_promoter jsonb, p_organization jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_person public.org_people;
  v_designation text := coalesce(p_organization->>'designation','PROMOTER');
  v_person_id uuid := nullif(p_organization->>'person_id','')::uuid;
  v_mobile text := coalesce(nullif(trim(p_mobile),''),p_login);
  v_matches uuid[];
begin
  if not exists(select 1 from public.app_users where id=p_actor and role='admin' and is_active) then
    raise exception 'ADMIN_ONLY';
  end if;
  if v_designation not in ('PROMOTER','TSE','MER') then raise exception 'Invalid field role'; end if;
  if nullif(trim(p_name),'') is null or nullif(trim(p_login),'') is null then
    raise exception 'Login ID and name are required';
  end if;
  -- Serialize same-mobile onboarding, including concurrent imports/requests
  -- using this RPC. Existing rows are locked again before claiming the link.
  perform pg_advisory_xact_lock(hashtextextended(v_mobile,0));
  if v_person_id is null then
    select array_agg(id) into v_matches from public.org_people
      where mobile=v_mobile and designation in ('PROMOTER','TSE','MER');
    if coalesce(cardinality(v_matches),0)>0 then
      raise exception 'An organizational record already uses this mobile. Select that employee in Organizational record instead of creating a duplicate.';
    end if;
  else
    select * into v_person from public.org_people where id=v_person_id for update;
    if v_person.id is null or not v_person.active or v_person.designation<>v_designation then
      raise exception 'The selected organizational record is unavailable. Refresh and select an active employee.';
    end if;
    if v_person.auth_user_id is not null then raise exception 'This employee already has a linked login'; end if;
  end if;

  insert into public.app_users(id,role,login_id,full_name,mobile)
    values(p_user_id,'promoter',p_login,trim(p_name),v_mobile);
  insert into public.promoters(user_id,promoter_code,promoter_type,agency_name,supervisor_id,home_state_id)
    values(p_user_id,coalesce(nullif(trim(p_promoter->>'promoter_code'),''),v_designation||'-'||p_user_id::text),
      coalesce(nullif(p_promoter->>'promoter_type',''),'permanent')::public.promoter_type,
      nullif(p_promoter->>'agency_name',''),nullif(p_promoter->>'supervisor_id','')::uuid,
      nullif(p_promoter->>'home_state_id','')::uuid);
  if v_person_id is null then
    insert into public.org_people(designation,employee_name,mobile,source_key,source_system,
      state_raw,market_raw,area_raw,beat_values,auth_user_id)
    values(v_designation,trim(p_name),v_mobile,'USER:'||p_user_id::text,'admin',
      nullif(trim(p_organization->>'state'),''),nullif(trim(p_organization->>'market'),''),
      nullif(trim(p_organization->>'area'),''),
      case when nullif(trim(p_organization->>'beat'),'') is null then '[]'::jsonb
        else jsonb_build_array(trim(p_organization->>'beat')) end,p_user_id)
    returning id into v_person_id;
  else
    update public.org_people set auth_user_id=p_user_id,updated_at=now() where id=v_person_id;
  end if;
  perform public.write_audit_as(p_actor,'USER_CREATED','app_users',p_user_id::text,
    jsonb_build_object('role','promoter','designation',v_designation,'login_id',p_login,'org_person_id',v_person_id));
  return jsonb_build_object('ok',true,'id',p_user_id,'org_person_id',v_person_id);
end $$;
revoke all on function public.create_linked_field_user(uuid,uuid,text,text,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.create_linked_field_user(uuid,uuid,text,text,text,jsonb,jsonb) to service_role;
