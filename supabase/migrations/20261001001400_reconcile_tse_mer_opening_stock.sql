-- Reconcile opening snack stock for TSE/MER logins that use the promoter app
-- role. The existing promoter-only reconciliation remains unchanged.
create or replace function public.reconcile_org_staff_inventory()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r public.org_inventory;
  v_person uuid;
  v_user uuid;
  v_count integer;
  v_candidate uuid;
  v_prize record;
  v_on_hand integer;
  v_reserved integer;
  v_people_linked integer := 0;
  v_stock_seeded integer := 0;
  v_unmatched integer := 0;
  v_processed uuid[] := '{}';
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;

  -- Use the latest inventory row for each existing UP TSE/MER profile.
  for r in
    select i.* from public.org_inventory i
    where i.designation in ('TSE','MER')
    order by i.imported_at desc,i.source_row desc,i.id desc
  loop
    v_person := null;
    if r.person_id is not null then
      select p.id into v_person from public.org_people p
        where p.id=r.person_id and p.designation=r.designation and p.active;
    end if;
    if v_person is null and nullif(trim(r.fas_id),'') is not null then
      select count(*),(array_agg(p.id))[1] into v_count,v_candidate
        from public.org_people p where p.active and p.designation=r.designation and p.fas_id=trim(r.fas_id);
      if v_count=1 then v_person:=v_candidate; end if;
    end if;
    if v_person is null and nullif(trim(r.qa_employee_id),'') is not null then
      select count(*),(array_agg(p.id))[1] into v_count,v_candidate
        from public.org_people p where p.active and p.designation=r.designation and p.qa_employee_id=trim(r.qa_employee_id);
      if v_count=1 then v_person:=v_candidate; end if;
    end if;
    if v_person is null and nullif(regexp_replace(coalesce(r.mobile,''),'\D','','g'),'') is not null then
      select count(*),(array_agg(p.id))[1] into v_count,v_candidate
        from public.org_people p where p.active and p.designation=r.designation
          and regexp_replace(coalesce(p.mobile,''),'\D','','g')=regexp_replace(r.mobile,'\D','','g');
      if v_count=1 then v_person:=v_candidate; end if;
    end if;
    if v_person is null then
      select count(*),(array_agg(p.id))[1] into v_count,v_candidate
        from public.org_people p where p.active and p.designation=r.designation
          and public.org_match_key(p.employee_name)=public.org_match_key(r.employee_name)
          and public.org_match_key(p.state_raw)=public.org_match_key(r.state_raw)
          and public.org_match_key(p.market_raw)=public.org_match_key(r.market_raw)
          and public.org_match_key(p.area_raw)=public.org_match_key(r.area_raw);
      if v_count=1 then v_person:=v_candidate; end if;
    end if;
    if v_person is null then
      v_unmatched:=v_unmatched+1;
      continue;
    end if;
    if v_person=any(v_processed) then continue; end if;
    v_processed:=array_append(v_processed,v_person);
    update public.org_inventory set person_id=v_person where id=r.id and person_id is null;

    select p.auth_user_id into v_user from public.org_people p
      join public.app_users au on au.id=p.auth_user_id and au.role='promoter'
      join public.promoters pr on pr.user_id=au.id
      where p.id=v_person for update of p;
    if v_user is null then
      v_unmatched:=v_unmatched+1;
      continue;
    end if;
    v_people_linked:=v_people_linked+1;

    for v_prize in select id,code from public.prizes where code in ('SNACK5','SNACK10') loop
      if exists(select 1 from public.inventory_movements m where m.promoter_id=v_user and m.prize_id=v_prize.id) then
        continue;
      end if;
      v_on_hand:=case when v_prize.code='SNACK5' then greatest(0,r.snack5_initial) else greatest(0,r.snack10_initial) end;
      if v_on_hand=0 then continue; end if;
      select i.on_hand,i.reserved into v_on_hand,v_reserved from public.promoter_inventory i
        where i.promoter_id=v_user and i.prize_id=v_prize.id for update;
      if found and (coalesce(v_on_hand,0)<>0 or coalesce(v_reserved,0)<>0) then continue; end if;
      v_on_hand:=case when v_prize.code='SNACK5' then greatest(0,r.snack5_initial) else greatest(0,r.snack10_initial) end;
      insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved)
        values(v_user,v_prize.id,v_on_hand,0)
        on conflict(promoter_id,prize_id) do update set on_hand=excluded.on_hand,reserved=0,updated_at=now();
      insert into public.inventory_movements(promoter_id,prize_id,movement_type,qty,on_hand_after,performed_by,reference,note)
        values(v_user,v_prize.id,'issue',v_on_hand,v_on_hand,auth.uid(),
          'org-staff-reconcile:'||r.id::text,'Reconciled opening stock for linked TSE/MER app account');
      v_stock_seeded:=v_stock_seeded+1;
    end loop;
  end loop;

  perform public.write_audit('ORG_STAFF_INVENTORY_RECONCILED','org_inventory',null,
    jsonb_build_object('people_linked',v_people_linked,'stock_balances_seeded',v_stock_seeded,'unmatched_rows',v_unmatched));
  return jsonb_build_object('people_linked',v_people_linked,'stock_balances_seeded',v_stock_seeded,'unmatched_rows',v_unmatched);
end $$;

revoke all on function public.reconcile_org_staff_inventory() from public,anon;
grant execute on function public.reconcile_org_staff_inventory() to authenticated;
