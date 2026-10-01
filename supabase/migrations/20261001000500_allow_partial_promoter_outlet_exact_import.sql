-- Exact outlet access is enforced per promoter. A workbook can contain
-- unresolved promoters while still safely applying complete promoter lists.
create or replace function public.import_promoter_outlet_workbook_access(
  p_run_key text,
  p_rows jsonb,
  p_mode text,
  p_unresolved_count integer default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r jsonb;
  v_promoter uuid;
  v_outlet uuid;
  v_promoter_count integer := 0;
  v_assignment_count integer := 0;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if length(coalesce(p_run_key,'')) < 8 then raise exception 'IMPORT_RUN_KEY_REQUIRED'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'PROMOTER_OUTLET_IMPORT_EMPTY'; end if;
  if p_mode is null or p_mode not in ('workbook_exact','workbook_additive') then raise exception 'PROMOTER_OUTLET_MODE_INVALID'; end if;
  if coalesce(p_unresolved_count,0) < 0 then raise exception 'PROMOTER_OUTLET_IMPORT_INVALID'; end if;

  -- Validate the complete payload before replacing any existing assignments.
  -- In exact mode, each included promoter must have a fully resolved outlet list.
  for r in select value from jsonb_array_elements(p_rows) loop
    if nullif(r->>'promoter_id','') is null or jsonb_typeof(r->'outlet_ids') is distinct from 'array' then raise exception 'PROMOTER_OUTLET_IMPORT_INVALID'; end if;
    v_promoter := (r->>'promoter_id')::uuid;
    if not exists(select 1 from public.org_people p where p.id=v_promoter and p.designation='PROMOTER' and p.active
      and public.org_match_key(p.state_raw) in ('uttarpradesh','up')) then
      raise exception 'PROMOTER_OUTLET_PROMOTER_INVALID';
    end if;
    if jsonb_array_length(r->'outlet_ids') = 0 then raise exception 'PROMOTER_OUTLET_IMPORT_EMPTY'; end if;
    if coalesce((r->>'unresolved_count')::integer,0) < 0 then raise exception 'PROMOTER_OUTLET_IMPORT_INVALID'; end if;
    if p_mode='workbook_exact' and coalesce((r->>'unresolved_count')::integer,0) <> 0 then
      raise exception 'PROMOTER_OUTLET_EXACT_REQUIRES_ALL_MATCHED' using hint='Resolve every outlet in this promoter list before applying exact access to that promoter.';
    end if;
    if exists (
      select 1 from jsonb_array_elements_text(r->'outlet_ids') x(value)
      left join public.outlets o on o.id=x.value::uuid and o.status='active'
      where o.id is null
    ) then raise exception 'PROMOTER_OUTLET_TARGET_INVALID'; end if;
  end loop;

  update public.org_people p set outlet_access_mode='mer',updated_at=now()
    where p.id in (select a.promoter_id from public.promoter_outlet_workbook_assignments a where a.source_state='UTTAR PRADESH');
  delete from public.promoter_outlet_workbook_assignments where source_state='UTTAR PRADESH';

  for r in select value from jsonb_array_elements(p_rows) loop
    v_promoter := (r->>'promoter_id')::uuid;
    update public.org_people set outlet_access_mode=p_mode,updated_at=now() where id=v_promoter;
    v_promoter_count := v_promoter_count + 1;
    for v_outlet in
      select distinct value::uuid from jsonb_array_elements_text(r->'outlet_ids') ids(value)
    loop
      insert into public.promoter_outlet_workbook_assignments(promoter_id,outlet_id,source_state,source_run_key)
      values(v_promoter,v_outlet,'UTTAR PRADESH',p_run_key)
      on conflict(promoter_id,outlet_id,source_state) do update set source_run_key=excluded.source_run_key,imported_at=now();
      v_assignment_count := v_assignment_count + 1;
    end loop;
  end loop;

  perform public.write_audit('PROMOTER_OUTLET_WORKBOOK_IMPORTED','promoter_outlet_workbook_assignments',p_run_key,
    jsonb_build_object('mode',p_mode,'promoters',v_promoter_count,'assignments',v_assignment_count,'unresolved',p_unresolved_count));
  return jsonb_build_object('promoter_count',v_promoter_count,'assignment_count',v_assignment_count,
    'mode',p_mode,'unresolved_count',coalesce(p_unresolved_count,0));
end $$;

revoke all on function public.import_promoter_outlet_workbook_access(text,jsonb,text,integer) from public,anon;
grant execute on function public.import_promoter_outlet_workbook_access(text,jsonb,text,integer) to authenticated;
