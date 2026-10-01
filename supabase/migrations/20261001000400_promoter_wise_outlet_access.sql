-- Import the UP Promoter Wise sheet as a promoter-specific outlet list.
-- Access mode is explicit: the workbook can replace inherited MER access or augment it.

alter table public.org_people
  add column if not exists outlet_access_mode text not null default 'mer'
  check (outlet_access_mode in ('mer','workbook_exact','workbook_additive'));

create table if not exists public.promoter_outlet_workbook_assignments (
  promoter_id uuid not null references public.org_people(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  source_state text not null,
  source_run_key text not null,
  imported_at timestamptz not null default now(),
  primary key (promoter_id, outlet_id, source_state)
);
create index if not exists promoter_outlet_workbook_outlet_idx
  on public.promoter_outlet_workbook_assignments(outlet_id);
alter table public.promoter_outlet_workbook_assignments enable row level security;
drop policy if exists promoter_outlet_workbook_admin_read on public.promoter_outlet_workbook_assignments;
create policy promoter_outlet_workbook_admin_read on public.promoter_outlet_workbook_assignments
  for select to authenticated using (public.is_admin());
revoke all on public.promoter_outlet_workbook_assignments from anon;
grant select on public.promoter_outlet_workbook_assignments to authenticated;

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
  if p_mode='workbook_exact' and coalesce(p_unresolved_count,0) <> 0 then
    raise exception 'PROMOTER_OUTLET_EXACT_REQUIRES_ALL_MATCHED' using hint='Resolve every promoter and outlet label to one unique active record before using exact access.';
  end if;

  -- Do not let an invalid payload partially replace current UP workbook assignments.
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
      raise exception 'PROMOTER_OUTLET_EXACT_REQUIRES_ALL_MATCHED' using hint='Resolve every promoter and outlet label to one unique active record before using exact access.';
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

create or replace function public.promoter_user_can_access_outlet(p_user_id uuid,p_outlet_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_mode text;
begin
  if not public.is_admin() and p_user_id is distinct from auth.uid()
    and not exists(select 1 from public.promoters pr where pr.user_id=p_user_id and pr.supervisor_id=auth.uid()) then
    return false;
  end if;
  select p.outlet_access_mode into v_mode from public.org_people p
    where p.auth_user_id=p_user_id and p.designation='PROMOTER' and p.active;
  if v_mode is null then return false; end if;
  if v_mode='workbook_exact' then
    return exists(
      select 1 from public.org_people p
      join public.promoter_outlet_workbook_assignments a on a.promoter_id=p.id and a.source_state='UTTAR PRADESH'
      join public.outlets o on o.id=a.outlet_id and o.status='active'
      where p.auth_user_id=p_user_id and p.designation='PROMOTER' and p.active and o.id=p_outlet_id
    );
  end if;
  return exists(
    select 1 from public.org_people p join public.outlets o on o.id=p_outlet_id and o.status='active'
    where p.auth_user_id=p_user_id and p.designation='PROMOTER' and p.active
      and (
        exists(select 1 from public.promoter_outlet_assignments a where a.promoter_id=p.id and a.outlet_id=o.id and a.active)
        or (v_mode='workbook_additive' and exists(select 1 from public.promoter_outlet_workbook_assignments a where a.promoter_id=p.id and a.outlet_id=o.id and a.source_state='UTTAR PRADESH'))
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

-- Keep roster/inventory reconciliation and outlet access replacement atomic.
create or replace function public.import_org_master_inventory_with_promoter_outlets(
  p_master jsonb,
  p_inventory jsonb,
  p_run_key text,
  p_outlet_rows jsonb,
  p_outlet_mode text,
  p_unresolved_count integer default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_master_result jsonb;
  v_outlet_result jsonb;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  v_master_result := public.import_org_master_inventory(p_master,p_inventory,p_run_key);
  v_outlet_result := public.import_promoter_outlet_workbook_access(p_run_key,p_outlet_rows,p_outlet_mode,p_unresolved_count);
  return v_master_result || jsonb_build_object('outlet_access',v_outlet_result);
end $$;

revoke all on function public.import_promoter_outlet_workbook_access(text,jsonb,text,integer) from public,anon;
grant execute on function public.import_promoter_outlet_workbook_access(text,jsonb,text,integer) to authenticated;
revoke all on function public.promoter_user_can_access_outlet(uuid,uuid) from public,anon;
grant execute on function public.promoter_user_can_access_outlet(uuid,uuid) to authenticated;
revoke all on function public.import_org_master_inventory_with_promoter_outlets(jsonb,jsonb,text,jsonb,text,integer) from public,anon;
grant execute on function public.import_org_master_inventory_with_promoter_outlets(jsonb,jsonb,text,jsonb,text,integer) to authenticated;
