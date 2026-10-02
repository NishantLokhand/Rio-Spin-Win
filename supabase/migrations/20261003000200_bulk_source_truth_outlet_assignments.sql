-- Apply source-of-truth outlet access with set-based outlet validation and
-- inserts. Preserve existing TSE/MER assignments; this importer is additive
-- for staff so a retry cannot remove manually or previously mapped access.
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
  v_valid_count integer;
  v_written integer;
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

    select coalesce(array_agg(distinct o.id) filter(where o.id is not null),'{}'::uuid[]),
           count(o.id)::integer
      into v_valid_ids,v_valid_count
      from jsonb_array_elements_text(v_ids) x(value)
      left join public.outlets o on o.id=case
        when x.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then x.value::uuid
        else null end and o.status='active';
    v_invalid_outlets := v_invalid_outlets + jsonb_array_length(v_ids) - v_valid_count;
    v_duplicate_ids := v_duplicate_ids + v_valid_count - cardinality(v_valid_ids);
    v_unresolved := v_unresolved + jsonb_array_length(v_ids) - v_valid_count;

    if p_promoter_mode='workbook_exact' and v_unresolved=0 then
      update public.org_people set outlet_access_mode='workbook_exact',updated_at=now() where id=v_person_id;
      delete from public.promoter_outlet_workbook_assignments
        where promoter_id=v_person_id and upper(source_state)=upper(v_source_state);
    elsif p_promoter_mode='workbook_exact' and v_unresolved>0 then
      update public.org_people set outlet_access_mode='workbook_additive',updated_at=now() where id=v_person_id;
      v_promoter_preserved := v_promoter_preserved+1;
    else
      update public.org_people set outlet_access_mode=p_promoter_mode,updated_at=now() where id=v_person_id;
    end if;

    insert into public.promoter_outlet_workbook_assignments(promoter_id,outlet_id,source_state,source_run_key)
    select v_person_id,ids.outlet_id,v_source_state,p_run_key from unnest(v_valid_ids) ids(outlet_id)
    on conflict(promoter_id,outlet_id,source_state) do update
      set source_run_key=excluded.source_run_key,imported_at=now();
    get diagnostics v_written = row_count;
    v_promoter_assignments := v_promoter_assignments+v_written;
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

    select coalesce(array_agg(distinct o.id) filter(where o.id is not null),'{}'::uuid[]),
           count(o.id)::integer
      into v_valid_ids,v_valid_count
      from jsonb_array_elements_text(v_ids) x(value)
      left join public.outlets o on o.id=case
        when x.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then x.value::uuid
        else null end and o.status='active';
    v_invalid_outlets := v_invalid_outlets + jsonb_array_length(v_ids) - v_valid_count;
    v_duplicate_ids := v_duplicate_ids + v_valid_count - cardinality(v_valid_ids);
    v_unresolved := v_unresolved + jsonb_array_length(v_ids) - v_valid_count;

    -- Add valid outlet links on every retry; never delete existing staff links.
    if v_unresolved>0 then v_staff_preserved := v_staff_preserved+1; end if;
    insert into public.org_person_outlet_workbook_assignments(person_id,outlet_id,source_state,source_run_key)
    select v_person_id,ids.outlet_id,v_source_state,p_run_key from unnest(v_valid_ids) ids(outlet_id)
    on conflict(person_id,outlet_id,source_state) do update
      set source_run_key=excluded.source_run_key,imported_at=now();
    get diagnostics v_written = row_count;
    v_staff_assignments := v_staff_assignments+v_written;
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

revoke all on function public.import_org_source_of_truth_access(text,text,jsonb,jsonb) from public,anon;
grant execute on function public.import_org_source_of_truth_access(text,text,jsonb,jsonb) to authenticated;
