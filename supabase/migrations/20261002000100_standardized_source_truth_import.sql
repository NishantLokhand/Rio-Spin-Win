-- Add a single-workbook import RPC. This is additive: the existing master,
-- inventory, outlet-access, and row-security functions remain in place.
-- Employee keys resolve to org_people.source_key after the roster upsert.

create or replace function public.import_org_source_of_truth_access(
  p_run_key text,
  p_promoter_mode text,
  p_promoter_rows jsonb,
  p_staff_rows jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r jsonb;
  v_person_id uuid;
  v_person_role text;
  v_person_state text;
  v_source_state text;
  v_outlet_text text;
  v_outlet_id uuid;
  v_unresolved integer;
  v_promoters integer := 0;
  v_promoter_assignments integer := 0;
  v_promoter_preserved integer := 0;
  v_staff integer := 0;
  v_staff_assignments integer := 0;
  v_staff_preserved integer := 0;
  v_missing_people integer := 0;
  v_invalid_outlets integer := 0;
  v_duplicate_ids integer := 0;
  v_ids jsonb;
  v_valid_ids uuid[];
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if length(coalesce(p_run_key,'')) < 8 then raise exception 'IMPORT_RUN_KEY_REQUIRED'; end if;
  if p_promoter_mode not in ('workbook_exact','workbook_additive') then raise exception 'PROMOTER_OUTLET_MODE_INVALID'; end if;
  if jsonb_typeof(p_promoter_rows) is distinct from 'array'
    or jsonb_typeof(p_staff_rows) is distinct from 'array' then raise exception 'IMPORT_INVALID_PAYLOAD'; end if;

  for r in select value from jsonb_array_elements(p_promoter_rows) loop
    select p.id,p.designation,p.state_raw into v_person_id,v_person_role,v_person_state
      from public.org_people p where p.source_key=nullif(trim(r->>'employee_key'),'') and p.active;
    if v_person_id is null or v_person_role <> 'PROMOTER' then
      v_missing_people := v_missing_people+1; continue;
    end if;
    v_source_state := upper(coalesce(nullif(trim(r->>'source_state'),''),v_person_state,''));
    if lower(regexp_replace(v_source_state,'[^a-z0-9]','','g')) in ('up','uttarpradesh') then v_source_state := 'UTTAR PRADESH';
    elsif lower(regexp_replace(v_source_state,'[^a-z0-9]','','g')) in ('mh','maharashtra','maharashtrarom') then v_source_state := 'MAHARASHTRA'; end if;
    v_unresolved := greatest(0,coalesce(nullif(r->>'unresolved_count','')::integer,0));
    v_ids := case when jsonb_typeof(r->'outlet_ids')='array' then r->'outlet_ids' else '[]'::jsonb end;
    v_valid_ids := '{}'::uuid[];
    for v_outlet_text in select jsonb_array_elements_text(v_ids) loop
      if v_outlet_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_invalid_outlets := v_invalid_outlets+1; v_unresolved := v_unresolved+1; continue;
      end if;
      v_outlet_id := v_outlet_text::uuid;
      if not exists(select 1 from public.outlets o where o.id=v_outlet_id and o.status='active') then
        v_invalid_outlets := v_invalid_outlets+1; v_unresolved := v_unresolved+1; continue;
      end if;
      if v_outlet_id = any(v_valid_ids) then v_duplicate_ids := v_duplicate_ids+1;
      else v_valid_ids := array_append(v_valid_ids,v_outlet_id); end if;
    end loop;

    if p_promoter_mode='workbook_exact' and v_unresolved>0 then
      v_promoter_preserved := v_promoter_preserved+1; continue;
    end if;
    update public.org_people set outlet_access_mode=p_promoter_mode,updated_at=now() where id=v_person_id;
    if p_promoter_mode='workbook_exact' then
      delete from public.promoter_outlet_workbook_assignments
        where promoter_id=v_person_id and upper(source_state)=upper(v_source_state);
    end if;
    foreach v_outlet_id in array v_valid_ids loop
      insert into public.promoter_outlet_workbook_assignments(promoter_id,outlet_id,source_state,source_run_key)
      values(v_person_id,v_outlet_id,v_source_state,p_run_key)
      on conflict(promoter_id,outlet_id,source_state) do update
        set source_run_key=excluded.source_run_key,imported_at=now();
      v_promoter_assignments := v_promoter_assignments+1;
    end loop;
    v_promoters := v_promoters+1;
  end loop;

  for r in select value from jsonb_array_elements(p_staff_rows) loop
    select p.id,p.designation,p.state_raw into v_person_id,v_person_role,v_person_state
      from public.org_people p where p.source_key=nullif(trim(r->>'employee_key'),'') and p.active;
    if v_person_id is null or v_person_role not in ('MER','TSE') then
      v_missing_people := v_missing_people+1; continue;
    end if;
    v_source_state := upper(coalesce(nullif(trim(r->>'source_state'),''),v_person_state,''));
    if lower(regexp_replace(v_source_state,'[^a-z0-9]','','g')) in ('up','uttarpradesh') then v_source_state := 'UTTAR PRADESH';
    elsif lower(regexp_replace(v_source_state,'[^a-z0-9]','','g')) in ('mh','maharashtra','maharashtrarom') then v_source_state := 'MAHARASHTRA'; end if;
    v_unresolved := greatest(0,coalesce(nullif(r->>'unresolved_count','')::integer,0));
    v_ids := case when jsonb_typeof(r->'outlet_ids')='array' then r->'outlet_ids' else '[]'::jsonb end;
    v_valid_ids := '{}'::uuid[];
    for v_outlet_text in select jsonb_array_elements_text(v_ids) loop
      if v_outlet_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_invalid_outlets := v_invalid_outlets+1; v_unresolved := v_unresolved+1; continue;
      end if;
      v_outlet_id := v_outlet_text::uuid;
      if not exists(select 1 from public.outlets o where o.id=v_outlet_id and o.status='active') then
        v_invalid_outlets := v_invalid_outlets+1; v_unresolved := v_unresolved+1; continue;
      end if;
      if v_outlet_id = any(v_valid_ids) then v_duplicate_ids := v_duplicate_ids+1;
      else v_valid_ids := array_append(v_valid_ids,v_outlet_id); end if;
    end loop;

    if v_unresolved>0 then v_staff_preserved := v_staff_preserved+1;
    else delete from public.org_person_outlet_workbook_assignments
      where person_id=v_person_id and upper(source_state)=upper(v_source_state);
    end if;
    foreach v_outlet_id in array v_valid_ids loop
      insert into public.org_person_outlet_workbook_assignments(person_id,outlet_id,source_state,source_run_key)
      values(v_person_id,v_outlet_id,v_source_state,p_run_key)
      on conflict(person_id,outlet_id,source_state) do update
        set source_run_key=excluded.source_run_key,imported_at=now();
      v_staff_assignments := v_staff_assignments+1;
    end loop;
    v_staff := v_staff+1;
  end loop;

  perform public.write_audit('ORG_SOURCE_OF_TRUTH_ACCESS_IMPORTED','org_people',p_run_key,
    jsonb_build_object('promoters',v_promoters,'promoter_assignments',v_promoter_assignments,
      'promoters_preserved',v_promoter_preserved,'staff',v_staff,'staff_assignments',v_staff_assignments,
      'staff_preserved',v_staff_preserved,'missing_people',v_missing_people,
      'invalid_outlets',v_invalid_outlets,'duplicate_outlet_ids',v_duplicate_ids));
  return jsonb_build_object('promoters',v_promoters,'assignments',v_promoter_assignments,'preserved',v_promoter_preserved,
    'staff',v_staff,'staff_assignments',v_staff_assignments,'staff_preserved',v_staff_preserved,
    'missing_people',v_missing_people,'invalid_outlets',v_invalid_outlets,'duplicate_outlet_ids',v_duplicate_ids);
end $$;

create or replace function public.import_org_source_of_truth(
  p_master jsonb,
  p_inventory jsonb,
  p_run_key text,
  p_promoter_mode text,
  p_promoter_rows jsonb,
  p_staff_rows jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_master_result jsonb;
  v_access_result jsonb;
  v_staff_links jsonb;
  v_promoter_stock jsonb;
  v_staff_stock jsonb;
  r jsonb;
  v_person_id uuid;
  v_source_row integer;
  v_inventory_linked integer := 0;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  v_master_result := public.import_org_master_inventory(p_master,p_inventory,p_run_key);

  -- The flat workbook uses employee_key for inventory relationships. The
  -- older inventory importer also supports legacy mobile/FAS/QA matching;
  -- correct its best-effort match to this exact key whenever the row exists.
  for r in select value from jsonb_array_elements(p_inventory) loop
    v_source_row := nullif(r->>'source_row','')::integer;
    if v_source_row is null then continue; end if;
    select p.id into v_person_id from public.org_people p
      where p.source_key=nullif(trim(r->>'employee_key'),'') and p.active
        and p.designation=upper(r->>'designation');
    if v_person_id is null then continue; end if;
    update public.org_inventory i set person_id=v_person_id
      where i.source_run_key=p_run_key and i.source_row=v_source_row
        and i.designation=upper(r->>'designation') and i.employee_name=trim(r->>'employee_name')
        and i.person_id is distinct from v_person_id;
    if found then v_inventory_linked := v_inventory_linked+1; end if;
  end loop;

  v_access_result := public.import_org_source_of_truth_access(p_run_key,p_promoter_mode,p_promoter_rows,p_staff_rows);
  v_staff_links := public.link_org_staff_accounts_from_inventory();
  v_promoter_stock := public.reconcile_org_promoter_inventory();
  v_staff_stock := public.reconcile_org_staff_inventory();
  return v_master_result || jsonb_build_object('outlet_access',v_access_result,
    'inventory_rows_linked_by_employee_key',v_inventory_linked,'staff_login_links',v_staff_links,
    'promoter_stock_reconciliation',v_promoter_stock,'staff_stock_reconciliation',v_staff_stock);
end $$;

revoke all on function public.import_org_source_of_truth_access(text,text,jsonb,jsonb) from public,anon;
grant execute on function public.import_org_source_of_truth_access(text,text,jsonb,jsonb) to authenticated;
revoke all on function public.import_org_source_of_truth(jsonb,jsonb,text,text,jsonb,jsonb) from public,anon;
grant execute on function public.import_org_source_of_truth(jsonb,jsonb,text,text,jsonb,jsonb) to authenticated;
