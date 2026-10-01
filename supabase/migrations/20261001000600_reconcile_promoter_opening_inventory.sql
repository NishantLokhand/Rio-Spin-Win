-- Repair opening snack stock that was imported to org_inventory but not issued
-- because the inventory row could not be linked at import time.
-- This never creates people/accounts and never changes a promoter/prize balance
-- that already has inventory movement history.
create or replace function public.reconcile_org_promoter_inventory()
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

  -- Newest row is authoritative if this workbook was imported under several keys.
  for r in
    select i.* from public.org_inventory i
    where i.designation='PROMOTER'
    order by i.imported_at desc, i.source_row desc, i.id desc
  loop
    v_person := r.person_id;

    -- Resolve only against existing PROMOTER master records. Prefer stable IDs,
    -- then mobile, then a unique name in the same state; market/area breaks ties.
    if v_person is null and nullif(trim(r.fas_id),'') is not null then
      select count(*),(array_agg(p.id))[1] into v_count,v_candidate
        from public.org_people p where p.designation='PROMOTER' and p.fas_id=trim(r.fas_id);
      if v_count=1 then v_person:=v_candidate; end if;
    end if;
    if v_person is null and nullif(trim(r.qa_employee_id),'') is not null then
      select count(*),(array_agg(p.id))[1] into v_count,v_candidate
        from public.org_people p where p.designation='PROMOTER' and p.qa_employee_id=trim(r.qa_employee_id);
      if v_count=1 then v_person:=v_candidate; end if;
    end if;
    if v_person is null and nullif(regexp_replace(coalesce(r.mobile,''),'\D','','g'),'') is not null then
      select count(*),(array_agg(p.id))[1] into v_count,v_candidate
        from public.org_people p where p.designation='PROMOTER'
          and regexp_replace(coalesce(p.mobile,''),'\D','','g')=regexp_replace(r.mobile,'\D','','g');
      if v_count=1 then v_person:=v_candidate; end if;
    end if;
    if v_person is null then
      select count(*),(array_agg(p.id))[1] into v_count,v_candidate
        from public.org_people p where p.designation='PROMOTER'
          and lower(regexp_replace(trim(p.employee_name),'\s+',' ','g'))=lower(regexp_replace(trim(r.employee_name),'\s+',' ','g'))
          and public.org_match_key(p.state_raw)=public.org_match_key(r.state_raw);
      if v_count=1 then v_person:=v_candidate;
      elsif v_count>1 then
        select count(*),(array_agg(p.id))[1] into v_count,v_candidate
          from public.org_people p where p.designation='PROMOTER'
            and lower(regexp_replace(trim(p.employee_name),'\s+',' ','g'))=lower(regexp_replace(trim(r.employee_name),'\s+',' ','g'))
            and public.org_match_key(p.state_raw)=public.org_match_key(r.state_raw)
            and (
              public.org_match_key(p.market_raw) in (public.org_match_key(r.market_raw),public.org_match_key(r.area_raw))
              or public.org_match_key(p.area_raw) in (public.org_match_key(r.market_raw),public.org_match_key(r.area_raw))
            );
        if v_count=1 then v_person:=v_candidate; end if;
      end if;
    end if;

    if v_person is null then
      v_unmatched:=v_unmatched+1;
      continue;
    end if;
    if v_person = any(v_processed) then continue; end if;
    v_processed:=array_append(v_processed,v_person);
    update public.org_inventory set person_id=v_person where id=r.id and person_id is null;

    select auth_user_id into v_user from public.org_people where id=v_person and designation='PROMOTER' for update;
    if v_user is not null and not exists(select 1 from public.app_users u join public.promoters pr on pr.user_id=u.id where u.id=v_user and u.role='promoter') then
      v_user:=null;
    end if;
    if v_user is null and nullif(regexp_replace(coalesce(r.mobile,''),'\D','','g'),'') is not null then
      select count(*),(array_agg(u.id))[1] into v_count,v_candidate
        from public.app_users u join public.promoters pr on pr.user_id=u.id
        where u.role='promoter'
          and regexp_replace(coalesce(nullif(u.mobile,''),u.login_id,''),'\D','','g')=regexp_replace(r.mobile,'\D','','g');
      if v_count=1 then v_user:=v_candidate; end if;
    end if;
    if v_user is null then
      select count(*),(array_agg(u.id))[1] into v_count,v_candidate
        from public.app_users u join public.promoters pr on pr.user_id=u.id
        where u.role='promoter'
          and lower(regexp_replace(trim(u.full_name),'\s+',' ','g'))=lower(regexp_replace(trim(r.employee_name),'\s+',' ','g'));
      if v_count=1 then v_user:=v_candidate; end if;
    end if;
    if v_user is null then
      v_unmatched:=v_unmatched+1;
      continue;
    end if;

    update public.org_people set auth_user_id=coalesce(auth_user_id,v_user),updated_at=now() where id=v_person;
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
          'org-reconcile:'||r.id::text,'Reconciled verified opening stock from organizational inventory');
      v_stock_seeded:=v_stock_seeded+1;
    end loop;
  end loop;

  perform public.write_audit('ORG_PROMOTER_INVENTORY_RECONCILED','org_inventory',null,
    jsonb_build_object('people_linked',v_people_linked,'stock_balances_seeded',v_stock_seeded,'unmatched_rows',v_unmatched));
  return jsonb_build_object('people_linked',v_people_linked,'stock_balances_seeded',v_stock_seeded,'unmatched_rows',v_unmatched);
end $$;

revoke all on function public.reconcile_org_promoter_inventory() from public,anon;
grant execute on function public.reconcile_org_promoter_inventory() to authenticated;
