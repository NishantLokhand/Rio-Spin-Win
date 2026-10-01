-- Regional outlet resolution:
--   * UP keeps its direct Promoter Wise and MER/TSE outlet lists.
--   * Maharashtra has roster beats rather than outlet-name tabs, so access
--     derives only from existing outlets on the employee's state/market beats.

create or replace function public.org_person_route_matches_outlet(p_person_id uuid,p_outlet_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists (
    select 1
    from public.org_people p
    join public.outlets o on o.id=p_outlet_id and o.status='active'
    join public.tses t on t.id=o.tse_id
    join public.territories tr on tr.id=t.territory_id
    join public.states st on st.id=tr.state_id
    where p.id=p_person_id and p.active
      and p.designation in ('PROMOTER','MER','TSE')
      and (
        public.org_match_key(p.state_raw)=public.org_match_key(st.name)
        or (public.org_match_key(p.state_raw)='up' and public.org_match_key(st.name)='uttarpradesh')
        or (public.org_match_key(p.state_raw)='mh' and public.org_match_key(st.name)='maharashtra')
        or (public.org_match_key(p.state_raw)='maharashtrarom' and public.org_match_key(st.name)='maharashtra')
      )
      and nullif(public.org_match_key(o.beat),'') is not null
      and exists (
        select 1 from jsonb_array_elements_text(coalesce(p.beat_override,p.beat_values,'[]'::jsonb)) b(value)
        where public.org_match_key(b.value)=public.org_match_key(o.beat)
      )
      and (
        -- Market can be the state (UP) or a city/territory (Maharashtra).
        (nullif(public.org_match_key(p.area_raw),'') is not null and (
          public.org_match_key(p.area_raw)=nullif(public.org_match_key(tr.name),'')
          or public.org_match_key(p.area_raw)=nullif(public.org_match_key(o.area),'')
          or public.org_match_key(p.area_raw)=nullif(public.org_match_key(o.city),'')
          or position(nullif(public.org_match_key(o.city),'') in public.org_match_key(p.area_raw))>0
          or position(nullif(public.org_match_key(o.area),'') in public.org_match_key(p.area_raw))>0
          or position(nullif(public.org_match_key(tr.name),'') in public.org_match_key(p.area_raw))>0
        ))
        or (nullif(public.org_match_key(p.market_raw),'') is not null and (
          public.org_match_key(p.market_raw)=nullif(public.org_match_key(tr.name),'')
          or public.org_match_key(p.market_raw)=nullif(public.org_match_key(o.area),'')
          or public.org_match_key(p.market_raw)=nullif(public.org_match_key(o.city),'')
          or position(nullif(public.org_match_key(o.city),'') in public.org_match_key(p.market_raw))>0
          or position(nullif(public.org_match_key(o.area),'') in public.org_match_key(p.market_raw))>0
          or position(nullif(public.org_match_key(tr.name),'') in public.org_match_key(p.market_raw))>0
        ))
        -- If source labels differ but the beat is unique to one territory in
        -- this state, the beat itself is a safe route key.
        or (select count(distinct tr2.id)
            from public.outlets o2
            join public.tses t2 on t2.id=o2.tse_id
            join public.territories tr2 on tr2.id=t2.territory_id
            join public.states st2 on st2.id=tr2.state_id
            where o2.status='active'
              and public.org_match_key(st2.name)=public.org_match_key(st.name)
              and public.org_match_key(o2.beat)=public.org_match_key(o.beat))=1
      )
  );
$$;

create or replace function public.promoter_user_can_access_outlet(p_user_id uuid,p_outlet_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_mode text; v_person public.org_people; v_state text;
begin
  if not public.is_admin() and p_user_id is distinct from auth.uid()
    and not exists(select 1 from public.promoters pr where pr.user_id=p_user_id and pr.supervisor_id=auth.uid()) then
    return false;
  end if;
  select p.* into v_person from public.org_people p
    where p.auth_user_id=p_user_id and p.active and p.designation in ('PROMOTER','MER','TSE');
  if v_person.id is null then return false; end if;

  select st.name into v_state from public.outlets o
    join public.tses t on t.id=o.tse_id
    join public.territories tr on tr.id=t.territory_id
    join public.states st on st.id=tr.state_id
    where o.id=p_outlet_id and o.status='active';
  if v_state is null then return false; end if;

  if v_person.designation in ('MER','TSE') then
    if exists(select 1 from public.org_person_outlet_workbook_assignments a
      where a.person_id=v_person.id and a.outlet_id=p_outlet_id
        and public.org_match_key(a.source_state)=public.org_match_key(v_state)) then
      return true;
    end if;
    if public.org_match_key(v_state)='maharashtra'
      and public.org_person_route_matches_outlet(v_person.id,p_outlet_id) then return true; end if;
    if v_person.designation='TSE' then
      return exists(select 1 from public.outlets o join public.tses t on t.id=o.tse_id
        join public.territories tr on tr.id=t.territory_id join public.states st on st.id=tr.state_id
        where o.id=p_outlet_id and o.status='active'
          and public.org_match_key(st.name)=public.org_match_key(v_person.state_raw)
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
          ));
    end if;
    return false;
  end if;

  -- Maharashtra currently supplies beats but no direct outlet lists. Resolve
  -- promoters there from their own imported beats and existing outlets only.
  if public.org_match_key(v_person.state_raw) in ('maharashtra','maharashtrarom','mh')
    and public.org_person_route_matches_outlet(v_person.id,p_outlet_id) then
    return true;
  end if;

  select p.outlet_access_mode into v_mode from public.org_people p
    where p.id=v_person.id and p.designation='PROMOTER';
  if v_mode is null then return false; end if;
  if v_mode='workbook_exact' then
    return exists(select 1 from public.promoter_outlet_workbook_assignments a
      where a.promoter_id=v_person.id and a.outlet_id=p_outlet_id
        and public.org_match_key(a.source_state)=public.org_match_key(v_state));
  end if;
  return exists(select 1 from public.outlets o where o.id=p_outlet_id and o.status='active' and (
    exists(select 1 from public.promoter_outlet_assignments a where a.promoter_id=v_person.id and a.outlet_id=o.id and a.active)
    or (v_mode='workbook_additive' and exists(select 1 from public.promoter_outlet_workbook_assignments a
      where a.promoter_id=v_person.id and a.outlet_id=o.id
        and public.org_match_key(a.source_state)=public.org_match_key(v_state)))
    or exists(select 1 from (
      select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=v_person.id
      union select v_person.mapped_mer_id where v_person.mapped_mer_id is not null
    ) mapped join public.org_people m on m.id=mapped.mer_id and m.designation='MER' and m.active
      where public.org_person_route_matches_outlet(m.id,o.id))
  ));
end $$;

-- Link Maharashtra TSE/MER app accounts via the already-reconciled inventory
-- identity. UP links created by the prior import helper remain unchanged.
create or replace function public.link_org_staff_accounts_from_inventory()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r public.org_inventory;
  v_person_ids uuid[];
  v_person uuid;
  v_count integer;
  v_users uuid[];
  v_user uuid;
  v_linked integer:=0;
  v_unmatched integer:=0;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  for r in select i.* from public.org_inventory i where i.designation in ('TSE','MER')
    order by i.imported_at desc,i.source_row desc,i.id desc loop
    v_person:=null;
    if r.person_id is not null then
      select p.id into v_person from public.org_people p where p.id=r.person_id
        and p.designation=r.designation and p.active;
    end if;
    if v_person is null and nullif(trim(r.fas_id),'') is not null then
      select array_agg(p.id),count(*) into v_person_ids,v_count from public.org_people p
        where p.designation=r.designation and p.active and p.fas_id=trim(r.fas_id);
      if v_count=1 then v_person:=v_person_ids[1]; end if;
    end if;
    if v_person is null and nullif(trim(r.qa_employee_id),'') is not null then
      select array_agg(p.id),count(*) into v_person_ids,v_count from public.org_people p
        where p.designation=r.designation and p.active and p.qa_employee_id=trim(r.qa_employee_id);
      if v_count=1 then v_person:=v_person_ids[1]; end if;
    end if;
    if v_person is null and nullif(regexp_replace(coalesce(r.mobile,''),'\D','','g'),'') is not null then
      select array_agg(p.id),count(*) into v_person_ids,v_count from public.org_people p
        where p.designation=r.designation and p.active
          and regexp_replace(coalesce(p.mobile,''),'\D','','g')=regexp_replace(r.mobile,'\D','','g');
      if v_count=1 then v_person:=v_person_ids[1]; end if;
    end if;
    if v_person is null then
      select array_agg(p.id),count(*) into v_person_ids,v_count from public.org_people p
        where p.designation=r.designation and p.active
          and public.org_match_key(p.employee_name)=public.org_match_key(r.employee_name)
          and (public.org_match_key(p.state_raw)=public.org_match_key(r.state_raw)
            or (public.org_match_key(r.state_raw)='maharashtrarom' and public.org_match_key(p.state_raw)='maharashtra'))
          and public.org_match_key(p.market_raw)=public.org_match_key(r.market_raw)
          and public.org_match_key(p.area_raw)=public.org_match_key(r.area_raw);
      if v_count=1 then v_person:=v_person_ids[1]; end if;
    end if;
    if v_person is null then v_unmatched:=v_unmatched+1; continue; end if;

    if exists(select 1 from public.org_people p join public.app_users au on au.id=p.auth_user_id and au.role='promoter'
      join public.promoters pr on pr.user_id=au.id where p.id=v_person) then continue; end if;

    v_users:=null;
    if nullif(regexp_replace(coalesce(r.mobile,''),'\D','','g'),'') is not null then
      select array_agg(distinct au.id) into v_users from public.app_users au
        join public.promoters pr on pr.user_id=au.id and au.role='promoter'
        where regexp_replace(coalesce(nullif(au.mobile,''),au.login_id,''),'\D','','g')=regexp_replace(r.mobile,'\D','','g')
          and not exists(select 1 from public.org_people other where other.auth_user_id=au.id and other.id<>v_person);
    end if;
    if coalesce(array_length(v_users,1),0)=0 then
      select array_agg(distinct au.id) into v_users from public.app_users au
        join public.promoters pr on pr.user_id=au.id and au.role='promoter'
        where lower(regexp_replace(trim(au.full_name),'\s+',' ','g'))=lower(regexp_replace(trim(r.employee_name),'\s+',' ','g'))
          and not exists(select 1 from public.org_people other where other.auth_user_id=au.id and other.id<>v_person);
    end if;
    if coalesce(array_length(v_users,1),0)<>1 then v_unmatched:=v_unmatched+1; continue; end if;
    v_user:=v_users[1];
    update public.org_people set auth_user_id=v_user,updated_at=now()
      where id=v_person and auth_user_id is null;
    if found then v_linked:=v_linked+1; end if;
  end loop;
  perform public.write_audit('REGIONAL_STAFF_LOGINS_LINKED','org_people',null,
    jsonb_build_object('accounts_linked',v_linked,'unmatched_rows',v_unmatched));
  return jsonb_build_object('accounts_linked',v_linked,'unmatched_rows',v_unmatched);
end $$;

revoke all on function public.org_person_route_matches_outlet(uuid,uuid) from public,anon,authenticated;
revoke all on function public.promoter_user_can_access_outlet(uuid,uuid) from public,anon;
grant execute on function public.promoter_user_can_access_outlet(uuid,uuid) to authenticated;
revoke all on function public.link_org_staff_accounts_from_inventory() from public,anon;
grant execute on function public.link_org_staff_accounts_from_inventory() to authenticated;
