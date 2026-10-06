-- Allow source-truth MER routes with no mapped TSE to exist as operational
-- outlets, and allow only explicitly MER-mapped promoters to inherit them.
-- Existing TSE-backed outlet access and transaction behavior is preserved.

alter table public.outlets alter column tse_id drop not null;
alter table public.outlets add column if not exists state_id uuid references public.states(id);
alter table public.outlets add column if not exists territory_id uuid references public.territories(id);

update public.outlets o
   set territory_id=t.territory_id,
       state_id=tr.state_id
  from public.tses t
  join public.territories tr on tr.id=t.territory_id
 where o.tse_id=t.id and (o.territory_id is null or o.state_id is null);

alter table public.sales alter column tse_id drop not null;
alter table public.sales alter column tse_code drop not null;
alter table public.sales alter column tse_name drop not null;

create index if not exists outlets_state_territory_active_idx
  on public.outlets(state_id,territory_id) where status='active';

-- Import only MER-owned source-truth routes for which no source TSE has the
-- exact state+beat mapping. Outlet codes are deterministic so retries are safe.
create or replace function public.import_mer_no_tse_outlets(p_run_key text,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r jsonb; k text; v_state uuid; v_territory uuid; v_mer uuid; v_outlet uuid;
  v_code text; v_source_state text; v_inserted integer:=0; v_mer_links integer:=0;
  v_errors jsonb:='[]'::jsonb; v_row integer:=0; v_status public.record_status;
  v_existing_tse uuid; v_key text;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if length(coalesce(p_run_key,''))<8 then raise exception 'IMPORT_RUN_KEY_REQUIRED'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'MER_NO_TSE_IMPORT_INVALID'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_row:=v_row+1;
    begin
      if nullif(trim(r->>'state'),'') is null or nullif(trim(r->>'territory'),'') is null
        or nullif(trim(r->>'outlet_code'),'') is null or nullif(trim(r->>'outlet_name'),'') is null
        or nullif(trim(r->>'beat'),'') is null or jsonb_typeof(r->'mer_employee_keys') is distinct from 'array'
        or jsonb_array_length(r->'mer_employee_keys')=0 then raise exception 'MER_NO_TSE_IMPORT_INVALID_ROW'; end if;
      v_key:=public.org_match_key(r->>'beat');
      if v_key like '%moradabadinst%' then raise exception 'INSTITUTIONAL_ROUTE_OUT_OF_SCOPE'; end if;
      v_source_state:=case when public.org_match_key(r->>'state') in ('up','uttarpradesh') then 'UTTAR PRADESH'
        when public.org_match_key(r->>'state') in ('mh','maharashtra','maharashtrarom') then 'MAHARASHTRA'
        else upper(trim(r->>'state')) end;
      if exists(select 1 from public.org_people t where t.active and t.designation='TSE'
        and public.org_match_key(t.state_raw)=public.org_match_key(v_source_state)
        and exists(select 1 from jsonb_array_elements_text(coalesce(t.beat_override,t.beat_values,'[]'::jsonb)) b(value)
          where public.org_match_key(b.value)=v_key)) then
        raise exception 'TSE_MAPPING_EXISTS_FOR_ROUTE';
      end if;

      select id into v_state from public.states where public.org_match_key(name)=public.org_match_key(r->>'state')
        or public.org_match_key(code)=public.org_match_key(r->>'state') order by (public.org_match_key(name)=public.org_match_key(r->>'state')) desc limit 1;
      if v_state is null then raise exception 'OUTLET_STATE_NOT_FOUND'; end if;
      select id into v_territory from public.territories where state_id=v_state
        and public.org_match_key(name)=public.org_match_key(r->>'territory') limit 1;
      if v_territory is null then
        insert into public.territories(state_id,code,name)
        values(v_state,'MER-'||substr(encode(extensions.digest(public.org_match_key(r->>'territory'),'sha256'),'hex'),1,12),trim(r->>'territory'))
        on conflict(state_id,name) do update set name=excluded.name returning id into v_territory;
      end if;
      v_status:=case when lower(coalesce(r->>'status','active')) in ('inactive','n','no','0','closed') then 'inactive' else 'active' end;
      v_code:=trim(r->>'outlet_code');
      select id,tse_id into v_outlet,v_existing_tse from public.outlets where outlet_code=v_code;
      if v_outlet is not null and v_existing_tse is not null then
        raise exception 'OUTLET_CODE_ALREADY_TSE_MAPPED';
      elsif v_outlet is null then
        insert into public.outlets(tse_id,state_id,territory_id,outlet_code,name,area,beat,city,distributor,status,source)
        values(null,v_state,v_territory,v_code,trim(r->>'outlet_name'),nullif(trim(r->>'area'),''),
          nullif(trim(r->>'beat'),''),nullif(trim(r->>'city'),''),nullif(trim(r->>'distributor'),''),v_status,'upload')
        returning id into v_outlet;
        v_inserted:=v_inserted+1;
      else
        update public.outlets set state_id=v_state,territory_id=v_territory,name=trim(r->>'outlet_name'),
          area=nullif(trim(r->>'area'),''),beat=nullif(trim(r->>'beat'),''),city=nullif(trim(r->>'city'),''),
          distributor=nullif(trim(r->>'distributor'),''),status=v_status,updated_at=now()
        where id=v_outlet and tse_id is null;
      end if;

      for k in select jsonb_array_elements_text(r->'mer_employee_keys') loop
        select p.id into v_mer from public.org_people p where p.active and p.designation='MER'
          and p.source_key=trim(k) and public.org_match_key(p.state_raw)=public.org_match_key(v_source_state);
        if v_mer is null then raise exception 'MER_PROFILE_NOT_FOUND:%',k; end if;
        insert into public.org_person_outlet_workbook_assignments(person_id,outlet_id,source_state,source_run_key)
        values(v_mer,v_outlet,v_source_state,p_run_key)
        on conflict(person_id,outlet_id,source_state) do update set source_run_key=excluded.source_run_key,imported_at=now();
        v_mer_links:=v_mer_links+1;
      end loop;
    exception when others then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('row',v_row,'outlet_code',r->>'outlet_code','error',sqlerrm));
    end;
  end loop;
  perform public.write_audit('MER_NO_TSE_OUTLETS_IMPORTED','outlets',p_run_key,
    jsonb_build_object('inserted',v_inserted,'mer_assignments',v_mer_links,'errors',jsonb_array_length(v_errors)));
  return jsonb_build_object('inserted',v_inserted,'mer_assignments',v_mer_links,'errors',v_errors);
end $$;

-- A promoter inherits a no-TSE outlet only through an actual promoter→MER
-- relationship and the MER's explicit workbook outlet assignment.
create or replace function public.promoter_user_can_access_outlet(p_user_id uuid,p_outlet_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_mode text; v_person public.org_people; v_state text; v_direct_state text;
begin
  if not public.is_admin() and p_user_id is distinct from auth.uid()
    and not exists(select 1 from public.promoters pr where pr.user_id=p_user_id and pr.supervisor_id=auth.uid()) then return false; end if;
  select p.* into v_person from public.org_people p where p.auth_user_id=p_user_id and p.active
    and p.designation in ('PROMOTER','MER','TSE');
  if v_person.id is null then return false; end if;
  select coalesce(ds.name,ms.name),ds.name into v_state,v_direct_state
    from public.outlets o left join public.tses t on t.id=o.tse_id
    left join public.territories mt on mt.id=t.territory_id
    left join public.states ms on ms.id=mt.state_id
    left join public.states ds on ds.id=o.state_id
    where o.id=p_outlet_id and o.status='active';
  if v_state is null then return false; end if;

  if v_person.designation in ('MER','TSE') then
    if exists(select 1 from public.org_person_outlet_workbook_assignments a where a.person_id=v_person.id
      and a.outlet_id=p_outlet_id and public.org_match_key(a.source_state)=public.org_match_key(v_state)) then return true; end if;
    if public.org_match_key(v_state)='maharashtra' and public.org_person_route_matches_outlet(v_person.id,p_outlet_id) then return true; end if;
    if v_person.designation='TSE' then
      return exists(select 1 from public.outlets o join public.tses t on t.id=o.tse_id
        join public.territories tr on tr.id=t.territory_id join public.states st on st.id=tr.state_id
        where o.id=p_outlet_id and o.status='active' and public.org_match_key(st.name)=public.org_match_key(v_person.state_raw)
        and ((nullif(regexp_replace(coalesce(v_person.mobile,''),'\D','','g'),'') is not null
          and regexp_replace(coalesce(t.mobile,''),'\D','','g')=regexp_replace(v_person.mobile,'\D','','g')
          and (select count(*) from public.tses tm where regexp_replace(coalesce(tm.mobile,''),'\D','','g')=regexp_replace(v_person.mobile,'\D','','g'))=1)
        or (nullif(v_person.fas_id,'') is not null and t.external_ref=v_person.fas_id and (select count(*) from public.tses te where te.external_ref=v_person.fas_id)=1)
        or (nullif(v_person.qa_employee_id,'') is not null and t.external_ref=v_person.qa_employee_id and (select count(*) from public.tses te where te.external_ref=v_person.qa_employee_id)=1)
        or (nullif(regexp_replace(lower(trim(v_person.employee_name)),'\s+','','g'),'') is not null
          and regexp_replace(lower(trim(t.name)),'\s+','','g')=regexp_replace(lower(trim(v_person.employee_name)),'\s+','','g')
          and (select count(*) from public.tses tn where regexp_replace(lower(trim(tn.name)),'\s+','','g')=regexp_replace(lower(trim(v_person.employee_name)),'\s+','','g'))=1)));
    end if;
    return false;
  end if;

  -- No-TSE access requires both explicit relationship and explicit MER outlet
  -- assignment. It never falls back to beat/area similarity.
  if exists(select 1 from public.outlets o where o.id=p_outlet_id and o.status='active' and o.tse_id is null) then
    return exists(select 1 from public.outlets o cross join lateral (
      select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=v_person.id
      union select v_person.mapped_mer_id where v_person.mapped_mer_id is not null
      ) mapped join public.org_people m on m.id=mapped.mer_id and m.active and m.designation='MER'
      join public.org_person_outlet_workbook_assignments ma on ma.person_id=m.id and ma.outlet_id=o.id
      where o.id=p_outlet_id and o.status='active' and public.org_match_key(ma.source_state)=public.org_match_key(v_state)
        and not exists(select 1 from public.org_people t where t.active and t.designation='TSE'
          and public.org_match_key(t.state_raw)=public.org_match_key(v_state)
          and exists(select 1 from jsonb_array_elements_text(coalesce(t.beat_override,t.beat_values,'[]'::jsonb)) b(value)
            where public.org_match_key(b.value)=public.org_match_key(o.beat))));
  end if;

  if public.org_match_key(v_person.state_raw) in ('maharashtra','maharashtrarom','mh')
    and public.org_person_route_matches_outlet(v_person.id,p_outlet_id) then return true; end if;
  select p.outlet_access_mode into v_mode from public.org_people p where p.id=v_person.id and p.designation='PROMOTER';
  if v_mode is null then return false; end if;
  if v_mode='workbook_exact' then
    return exists(select 1 from public.promoter_outlet_workbook_assignments a where a.promoter_id=v_person.id
      and a.outlet_id=p_outlet_id and public.org_match_key(a.source_state)=public.org_match_key(v_state));
  end if;
  return exists(select 1 from public.outlets o where o.id=p_outlet_id and o.status='active' and (
    exists(select 1 from public.promoter_outlet_assignments a where a.promoter_id=v_person.id and a.outlet_id=o.id and a.active)
    or (v_mode='workbook_additive' and exists(select 1 from public.promoter_outlet_workbook_assignments a
      where a.promoter_id=v_person.id and a.outlet_id=o.id and public.org_match_key(a.source_state)=public.org_match_key(v_state)))
    or exists(select 1 from (select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=v_person.id
      union select v_person.mapped_mer_id where v_person.mapped_mer_id is not null) mapped
      join public.org_people m on m.id=mapped.mer_id and m.designation='MER' and m.active
      where (o.tse_id is not null and public.org_person_route_matches_outlet(m.id,o.id))
        or (o.tse_id is null and exists(select 1 from public.org_person_outlet_workbook_assignments ma
          where ma.person_id=m.id and ma.outlet_id=o.id and public.org_match_key(ma.source_state)=public.org_match_key(v_state))))
  ));
end $$;

-- Exact UP mode still permits only the promoter's list plus the narrowly
-- defined no-TSE MER fallback. Other fast outlet-list branches stay unchanged.
create or replace function public.get_promoter_outlets()
returns table(id uuid,outlet_code text,name text,area text,city text,tse_id uuid,beat text)
language plpgsql stable security definer set search_path=public as $$
declare v_person_id uuid; v_designation text; v_state text; v_access_mode text;
begin
  perform public._require_promoter();
  select p.id,p.designation,p.state_raw,p.outlet_access_mode into v_person_id,v_designation,v_state,v_access_mode
    from public.org_people p where p.auth_user_id=auth.uid() and p.active and p.designation in ('PROMOTER','MER','TSE');
  if v_person_id is null then return; end if;
  if v_designation='PROMOTER' and exists(select 1 from public.promoters pr where pr.user_id=auth.uid() and pr.promoter_code='TEST-9556600000') then
    return query select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat from public.promoter_outlet_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active' where a.promoter_id=v_person_id and a.active order by o.name; return;
  end if;
  if v_designation in ('MER','TSE') and public.org_match_key(v_state) in ('mh','maharashtra','maharashtrarom') then
    return query select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat from public.org_person_outlet_workbook_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active' where a.person_id=v_person_id
      and public.org_match_key(a.source_state) in ('mh','maharashtra','maharashtrarom') order by o.name; return;
  end if;
  if v_designation='PROMOTER' and public.org_match_key(v_state) in ('up','uttarpradesh') then
    if v_access_mode='workbook_exact' then
      return query select distinct o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat from public.outlets o where o.status='active'
        and (exists(select 1 from public.promoter_outlet_workbook_assignments a where o.tse_id is not null and a.promoter_id=v_person_id and a.outlet_id=o.id
              and public.org_match_key(a.source_state) in ('up','uttarpradesh'))
          or (o.tse_id is null and public.promoter_user_can_access_outlet(auth.uid(),o.id))) order by o.name; return;
    elsif v_access_mode='workbook_additive' then
      return query select distinct o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat from public.outlets o where o.status='active' and (
        exists(select 1 from public.promoter_outlet_assignments a where o.tse_id is not null and a.promoter_id=v_person_id and a.outlet_id=o.id and a.active)
        or exists(select 1 from public.promoter_outlet_workbook_assignments a where o.tse_id is not null and a.promoter_id=v_person_id and a.outlet_id=o.id
          and public.org_match_key(a.source_state) in ('up','uttarpradesh'))
        or (o.tse_id is null and public.promoter_user_can_access_outlet(auth.uid(),o.id))
        or exists(select 1 from (select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=v_person_id
          union select p.mapped_mer_id from public.org_people p where p.id=v_person_id and p.mapped_mer_id is not null) mapped
          join public.org_person_outlet_workbook_assignments a on a.person_id=mapped.mer_id and a.outlet_id=o.id
          where public.org_match_key(a.source_state) in ('up','uttarpradesh')
            and (o.tse_id is not null or public.promoter_user_can_access_outlet(auth.uid(),o.id)))
      ) order by o.name; return;
    end if;
  end if;
  if v_designation in ('MER','TSE') and public.org_match_key(v_state) in ('up','uttarpradesh')
    and exists(select 1 from public.org_person_outlet_workbook_assignments a where a.person_id=v_person_id
      and public.org_match_key(a.source_state) in ('up','uttarpradesh')) then
    return query select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat from public.org_person_outlet_workbook_assignments a
      join public.outlets o on o.id=a.outlet_id and o.status='active' where a.person_id=v_person_id
      and public.org_match_key(a.source_state) in ('up','uttarpradesh') order by o.name; return;
  end if;
  return query select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat from public.outlets o
    where o.status='active' and public.promoter_user_can_access_outlet(auth.uid(),o.id) order by o.name;
end $$;

create or replace function public.set_work_context(p_outlet_id uuid,p_device_ref text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u public.app_users; r record; v_campaign uuid; c public.campaigns;
begin
  u:=public._require_promoter();
  select o.id outlet_id,o.outlet_code,o.name outlet_name,o.area,o.city,t.id tse_id,t.name tse_name,
    coalesce(o.territory_id,t.territory_id) territory_id,coalesce(dt.name,mt.name) territory_name,
    coalesce(o.state_id,dt.state_id,mt.state_id) state_id,coalesce(ds.name,ms.name) state_name
    into r from public.outlets o left join public.tses t on t.id=o.tse_id
    left join public.territories mt on mt.id=t.territory_id left join public.states ms on ms.id=mt.state_id
    left join public.territories dt on dt.id=o.territory_id left join public.states ds on ds.id=o.state_id
    where o.id=p_outlet_id and o.status='active';
  if r.outlet_id is null or r.state_id is null or r.territory_id is null then
    raise exception 'OUTLET_NOT_ACTIVE' using hint='This outlet is missing its state or territory mapping.';
  end if;
  v_campaign:=public._resolve_campaign(u.id,r.state_id);
  select * into c from public.campaigns where id=v_campaign;
  insert into public.promoter_sessions(promoter_id,work_date,campaign_id,state_id,territory_id,tse_id,outlet_id,device_ref)
  values(u.id,public.ist_today(),v_campaign,r.state_id,r.territory_id,r.tse_id,r.outlet_id,p_device_ref)
  on conflict(promoter_id,work_date) do update set campaign_id=excluded.campaign_id,state_id=excluded.state_id,
    territory_id=excluded.territory_id,tse_id=excluded.tse_id,outlet_id=excluded.outlet_id,
    device_ref=coalesce(excluded.device_ref,public.promoter_sessions.device_ref),updated_at=now();
  perform public.write_audit('OUTLET_SELECTED','outlets',r.outlet_id::text,
    jsonb_build_object('outlet_code',r.outlet_code,'tse',r.tse_name,'device_ref',p_device_ref));
  return jsonb_build_object('outlet',to_jsonb(r),'campaign',case when c.id is null then null else jsonb_build_object(
    'id',c.id,'code',c.code,'name',c.name,'sound_default',c.sound_default,'spins_per_sale',c.spins_per_sale,
    'max_quantity_per_sale',c.max_quantity_per_sale,'validation_rules',c.validation_rules,'capture_consumer',c.capture_consumer) end);
end $$;

-- Verify selected directory metadata against the outlet's direct state when
-- there is no TSE; selection still snapshots license/address to the session.
create or replace function public.set_work_context_with_search(p_outlet_id uuid,p_device_ref text default null,p_directory_record_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb; v_license text; v_address text;
begin
  perform public._require_promoter();
  v_result:=public.set_work_context(p_outlet_id,p_device_ref);
  if p_directory_record_id is not null then
    select d.license_no,d.address into v_license,v_address from public.outlet_search_master d
      join public.outlets o on o.id=p_outlet_id
      left join public.tses t on t.id=o.tse_id left join public.territories tr on tr.id=t.territory_id
      left join public.states st on st.id=coalesce(o.state_id,tr.state_id)
      where d.id=p_directory_record_id and d.is_active and d.state_code='UP' and upper(st.code)='UP'
        and d.normalized_outlet_name=public.normalize_outlet_search_text(o.name);
    if not found then raise exception 'OUTLET_SEARCH_MATCH_INVALID'; end if;
  end if;
  update public.promoter_sessions set outlet_search_master_id=p_directory_record_id,outlet_license_no=v_license,
    outlet_address=v_address,updated_at=now() where promoter_id=auth.uid() and work_date=public.ist_today() and outlet_id=p_outlet_id;
  if not found then raise exception 'WORK_SESSION_NOT_FOUND'; end if;
  if p_directory_record_id is not null then perform public.write_audit('OUTLET_IDENTIFICATION_SELECTED','outlets',p_outlet_id::text,
    jsonb_build_object('directory_record_id',p_directory_record_id,'license_no',v_license,'address',v_address)); end if;
  return v_result;
end $$;

create or replace function public.search_authorized_outlets(p_outlet_name text default null,p_address text default null,p_license_no text default null,p_limit integer default 30,p_offset integer default 0)
returns table(id uuid,outlet_code text,name text,area text,city text,tse_id uuid,beat text,directory_record_id uuid,license_no text,address text,total_count bigint)
language plpgsql stable security definer set search_path=public as $$
declare v_name text:=nullif(public.normalize_outlet_search_text(p_outlet_name),'');
  v_address text:=nullif(public.normalize_outlet_search_text(p_address),''); v_license text:=nullif(public.normalize_outlet_search_text(p_license_no),'');
  v_limit integer:=greatest(1,least(coalesce(p_limit,30),50)); v_offset integer:=greatest(0,coalesce(p_offset,0));
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_name is null and v_address is null and v_license is null then raise exception 'SEARCH_TERM_REQUIRED'; end if;
  if (v_name is not null and length(v_name)<2) or (v_address is not null and length(v_address)<2) or (v_license is not null and length(v_license)<2) then raise exception 'SEARCH_TERM_TOO_SHORT'; end if;
  return query with authorized as (
    select a.id,a.outlet_code,a.name,a.area,a.city,a.tse_id,a.beat,d.id directory_record_id,d.license_no,d.address
    from public.get_promoter_outlets() a join public.outlets o on o.id=a.id
    left join public.tses t on t.id=o.tse_id left join public.territories tr on tr.id=t.territory_id
    left join public.states st on st.id=coalesce(o.state_id,tr.state_id)
    left join lateral (select m.id,m.license_no,m.address,m.normalized_license_no,m.normalized_address
      from public.outlet_search_master m where m.is_active and upper(st.code)='UP' and m.state_code='UP'
      and m.normalized_outlet_name=public.normalize_outlet_search_text(o.name)
      order by m.license_no nulls last,m.address nulls last,m.id) d on true
    where (v_name is null or public.normalize_outlet_search_text(a.name) like '%'||v_name||'%'
      or public.normalize_outlet_search_text(a.outlet_code) like '%'||v_name||'%'
      or public.normalize_outlet_search_text(a.area) like '%'||v_name||'%' or public.normalize_outlet_search_text(a.city) like '%'||v_name||'%')
      and (v_address is null or d.normalized_address like '%'||v_address||'%')
      and (v_license is null or d.normalized_license_no like '%'||v_license||'%'))
  select a.id,a.outlet_code,a.name,a.area,a.city,a.tse_id,a.beat,a.directory_record_id,a.license_no,a.address,count(*) over()
    from authorized a order by a.name,a.area nulls last,a.outlet_code,a.license_no nulls last,a.address nulls last limit v_limit offset v_offset;
end $$;

-- Preserve the legacy TSE snapshot when present; no-TSE sales retain the
-- supplied territory/state, with the TSE snapshot columns intentionally null.
create or replace function public.record_sale(p_sale_id uuid,p_outlet_id uuid,p_product_id uuid,p_quantity int,
  p_device_ref text default null,p_validation jsonb default '{}'::jsonb,p_client_time timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u public.app_users; pr public.promoters; s public.sales; c public.campaigns; cfg public.prize_configs;
  r record; p public.products; v_campaign uuid; v_problem text; v_used numeric; v_budget numeric; v_key text; k text; v text;
begin
  u:=public._require_promoter();
  select * into s from public.sales where id=p_sale_id;
  if s.id is not null then
    if s.promoter_id<>u.id then raise exception 'SALE_NOT_FOUND'; end if;
    return jsonb_build_object('sale_id',s.id,'status',s.status,'spins_allowed',s.spins_allowed,'spins_used',s.spins_used,'replayed',true);
  end if;
  if exists(select 1 from public.spins where promoter_id=u.id and redemption_status='pending') then
    raise exception 'PENDING_HANDOVER' using hint='Hand over the previous prize before starting a new sale.'; end if;
  select * into pr from public.promoters where user_id=u.id;
  if pr.user_id is null then raise exception 'PROMOTER_PROFILE_MISSING'; end if;
  select o.id outlet_id,o.outlet_code,o.name outlet_name,o.area,o.city,o.distributor,t.id tse_id,t.code tse_code,t.name tse_name,
    coalesce(o.territory_id,t.territory_id) territory_id,coalesce(dt.name,mt.name) territory_name,
    coalesce(o.state_id,dt.state_id,mt.state_id) state_id,coalesce(ds.name,ms.name) state_name
    into r from public.outlets o left join public.tses t on t.id=o.tse_id left join public.territories mt on mt.id=t.territory_id
    left join public.states ms on ms.id=mt.state_id left join public.territories dt on dt.id=o.territory_id
    left join public.states ds on ds.id=o.state_id where o.id=p_outlet_id and o.status='active';
  if r.outlet_id is null or r.state_id is null or r.territory_id is null then raise exception 'OUTLET_NOT_ACTIVE'; end if;
  v_campaign:=public._resolve_campaign(u.id,r.state_id);
  if v_campaign is null then raise exception 'NO_ACTIVE_CAMPAIGN' using hint='No active campaign covers this outlet''s state.'; end if;
  select * into c from public.campaigns where id=v_campaign;
  select * into p from public.products where id=p_product_id and is_active;
  if p.id is null then raise exception 'PRODUCT_NOT_ALLOWED'; end if;
  if exists(select 1 from public.campaign_products where campaign_id=c.id)
    and not exists(select 1 from public.campaign_products where campaign_id=c.id and product_id=p.id) then raise exception 'PRODUCT_NOT_ALLOWED'; end if;
  if p_quantity is null or p_quantity<1 or p_quantity>c.max_quantity_per_sale then raise exception 'INVALID_QUANTITY' using hint=format('Quantity must be 1–%s',c.max_quantity_per_sale); end if;
  for k,v in select key,value #>> '{}' from jsonb_each(c.validation_rules) loop
    if v='required' and coalesce(nullif(p_validation->>k,''),'')='' then raise exception 'VALIDATION_REQUIRED' using detail=k,hint=format('%s is required for this campaign',replace(k,'_',' ')); end if;
  end loop;
  if c.enforce_budget then
    select coalesce(sum(prize_cost),0) into v_used from public.spins where campaign_id=c.id and redemption_status<>'not_redeemed';
    if c.total_budget is not null and v_used>=c.total_budget then raise exception 'BUDGET_EXHAUSTED' using hint='Campaign budget fully used.'; end if;
    if c.daily_budget is not null then select coalesce(sum(prize_cost),0) into v_used from public.spins where campaign_id=c.id and biz_date=public.ist_today() and redemption_status<>'not_redeemed';
      if v_used>=c.daily_budget then raise exception 'BUDGET_EXHAUSTED' using hint='Today''s budget fully used.'; end if; end if;
    select budget into v_budget from public.campaign_states where campaign_id=c.id and state_id=r.state_id;
    if v_budget is not null then select coalesce(sum(sp.prize_cost),0) into v_used from public.spins sp join public.sales sa on sa.id=sp.sale_id where sp.campaign_id=c.id and sa.state_id=r.state_id and sp.redemption_status<>'not_redeemed';
      if v_used>=v_budget then raise exception 'BUDGET_EXHAUSTED' using hint='State budget fully used.'; end if; end if;
    select budget into v_budget from public.campaign_territory_budgets where campaign_id=c.id and territory_id=r.territory_id;
    if v_budget is not null then select coalesce(sum(sp.prize_cost),0) into v_used from public.spins sp join public.sales sa on sa.id=sp.sale_id where sp.campaign_id=c.id and sa.territory_id=r.territory_id and sp.redemption_status<>'not_redeemed';
      if v_used>=v_budget then raise exception 'BUDGET_EXHAUSTED' using hint='Territory budget fully used.'; end if; end if;
  end if;
  cfg:=public._active_config(c.id,r.state_id);
  if cfg.id is null then raise exception 'NO_PRIZE_CONFIG' using hint='Admin has not configured prizes for this campaign/state.'; end if;
  s.promoter_id:=u.id;s.outlet_id:=r.outlet_id;s.territory_id:=r.territory_id;s.state_id:=r.state_id;s.campaign_id:=c.id;
  v_key:=public._pool_key(c.pool_scope,s);v_problem:=public._stock_problem(c,cfg,u.id,v_key);
  if v_problem is not null then raise exception 'OUT_OF_STOCK' using detail=v_problem,hint='Replenish prize stock: '||v_problem; end if;
  update public.sales set status='cancelled',cancelled_reason='superseded by new sale' where promoter_id=u.id and status='open' and spins_used=0;
  insert into public.sales(id,campaign_id,biz_date,client_created_at,promoter_id,promoter_code,promoter_name,promoter_type,
    state_id,state_name,territory_id,territory_name,tse_id,tse_code,tse_name,outlet_id,outlet_code,outlet_name,outlet_area,outlet_city,distributor,
    product_id,sku_code,product_name,quantity,spins_allowed,validation,device_ref)
  values(p_sale_id,c.id,public.ist_today(),p_client_time,u.id,pr.promoter_code,u.full_name,pr.promoter_type,
    r.state_id,r.state_name,r.territory_id,r.territory_name,r.tse_id,r.tse_code,r.tse_name,r.outlet_id,r.outlet_code,r.outlet_name,r.area,r.city,r.distributor,
    p.id,p.sku_code,p.name,p_quantity,c.spins_per_sale,coalesce(p_validation,'{}'::jsonb),p_device_ref);
  perform public.write_audit('SALE_RECORDED','sales',p_sale_id::text,jsonb_build_object('outlet_code',r.outlet_code,'tse_code',r.tse_code,'sku',p.sku_code,'qty',p_quantity,'campaign',c.code,'device_ref',p_device_ref));
  return jsonb_build_object('sale_id',p_sale_id,'status','open','spins_allowed',c.spins_per_sale,'spins_used',0,'replayed',false);
end $$;

revoke all on function public.import_mer_no_tse_outlets(text,jsonb) from public,anon;
grant execute on function public.import_mer_no_tse_outlets(text,jsonb) to authenticated;
revoke all on function public.promoter_user_can_access_outlet(uuid,uuid),public.get_promoter_outlets() from public,anon;
grant execute on function public.promoter_user_can_access_outlet(uuid,uuid),public.get_promoter_outlets() to authenticated;
revoke all on function public.set_work_context(uuid,text),public.set_work_context_with_search(uuid,text,uuid),
  public.record_sale(uuid,uuid,uuid,integer,text,jsonb,timestamp with time zone),
  public.search_authorized_outlets(text,text,text,integer,integer) from public,anon;
grant execute on function public.set_work_context(uuid,text),public.set_work_context_with_search(uuid,text,uuid),
  public.record_sale(uuid,uuid,uuid,integer,text,jsonb,timestamp with time zone),
  public.search_authorized_outlets(text,text,text,integer,integer) to authenticated;

notify pgrst,'reload schema';
