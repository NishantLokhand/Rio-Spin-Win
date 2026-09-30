-- Adds source workbook row tracking to the inventory import for databases where
-- source_row is already required. Safe to run after 20260930000500.
alter table public.org_inventory add column if not exists source_row integer;
with missing_rows as (
  select id, row_number() over (partition by source_run_key order by imported_at, id)::integer as row_no
  from public.org_inventory where source_row is null
)
update public.org_inventory i set source_row = m.row_no
from missing_rows m where i.id = m.id;
alter table public.org_inventory alter column source_row set not null;
create or replace function public.import_org_master_inventory(p_master jsonb, p_inventory jsonb, p_run_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r jsonb; v_id uuid; v_count int:=0; v_inv int:=0; v_prize5 uuid; v_prize10 uuid; v_user uuid; v_person uuid;
        v_mob text; v_fas text; v_qa text; v_name text; v_role text; v_state text; v_market text; v_area text;
        v_qty5 int; v_qty10 int; v_existing boolean; v_prize uuid; v_qty int; v_seeded uuid; v_match_count int; v_source_row int;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if jsonb_typeof(p_master) <> 'array' or jsonb_typeof(p_inventory) <> 'array' then raise exception 'IMPORT_INVALID_PAYLOAD'; end if;
  if length(coalesce(p_run_key,'')) < 8 then raise exception 'IMPORT_RUN_KEY_REQUIRED'; end if;
  for r in select value from jsonb_array_elements(p_master) loop
    insert into public.org_people(designation,employee_name,mobile,fas_id,qa_employee_id,source_key,source_system,source_ids,
      state_raw,market_raw,zone_raw,area_raw,beat_values,assignment_source)
    values (upper(r->>'designation'),trim(r->>'employee_name'),nullif(trim(r->>'mobile'),''),nullif(trim(r->>'fas_id'),''),
      nullif(trim(r->>'qa_employee_id'),''),r->>'source_key',coalesce(r->>'source_system','source_file'),coalesce(r->'source_ids','{}'::jsonb),
      nullif(trim(r->>'state_raw'),''),nullif(trim(r->>'market_raw'),''),nullif(trim(r->>'zone_raw'),''),nullif(trim(r->>'area_raw'),''),coalesce(r->'beat_values','[]'::jsonb),'source_import')
    on conflict(source_key) do update set
      employee_name=excluded.employee_name, mobile=coalesce(excluded.mobile,org_people.mobile), fas_id=coalesce(excluded.fas_id,org_people.fas_id),
      qa_employee_id=coalesce(excluded.qa_employee_id,org_people.qa_employee_id),source_ids=org_people.source_ids||excluded.source_ids,
      state_raw=excluded.state_raw,market_raw=excluded.market_raw,zone_raw=excluded.zone_raw,area_raw=excluded.area_raw,
      beat_values=excluded.beat_values,updated_at=now()
    returning id into v_id;
    v_count:=v_count+1;
    if upper(r->>'designation')='PROMOTER' then
      v_user:=null;
      if nullif(regexp_replace(coalesce(r->>'mobile',''), '\D','','g'),'') is not null then
        select au.id into v_user from public.app_users au join public.promoters pr on pr.user_id=au.id
        where au.role='promoter' and regexp_replace(coalesce(au.mobile,au.login_id,''),'\D','','g')=regexp_replace(r->>'mobile','\D','','g') limit 1;
      end if;
      if v_user is null then
        select (array_agg(au.id))[1] into v_user from public.app_users au join public.promoters pr on pr.user_id=au.id
        where au.role='promoter' and lower(regexp_replace(trim(au.full_name),'\s+',' ','g'))=lower(regexp_replace(trim(r->>'employee_name'),'\s+',' ','g'))
        having count(*)=1;
      end if;
      if v_user is not null then update public.org_people set auth_user_id=coalesce(auth_user_id,v_user) where id=v_id; end if;
    end if;
  end loop;
  select id into v_prize5 from public.prizes where code='SNACK5';
  select id into v_prize10 from public.prizes where code='SNACK10';
  if v_prize5 is null or v_prize10 is null then raise exception 'SNACK_PRIZES_NOT_CONFIGURED'; end if;
  select exists(select 1 from public.org_import_runs where run_key=p_run_key) into v_existing;
  if not v_existing then
    for r in select value from jsonb_array_elements(p_inventory) loop
      v_name:=trim(r->>'employee_name'); v_role:=upper(r->>'designation'); v_mob:=nullif(regexp_replace(coalesce(r->>'mobile',''), '\D','','g'),'');
      v_source_row:=coalesce(nullif(r->>'source_row','')::int,v_inv+2);
      v_fas:=nullif(trim(r->>'fas_id'),''); v_qa:=nullif(trim(r->>'qa_employee_id'),'');
      v_state:=nullif(trim(r->>'state_raw'),''); v_market:=nullif(trim(r->>'market_raw'),''); v_area:=nullif(trim(r->>'area_raw'),'');
      v_qty5:=greatest(0,coalesce((r->>'snack5')::int,0)); v_qty10:=greatest(0,coalesce((r->>'snack10')::int,0));
      v_person:=null;
      if v_fas is not null then
        select count(*),(array_agg(p.id))[1] into v_match_count,v_id from public.org_people p where p.designation=v_role and p.fas_id=v_fas;
        if v_match_count=1 then v_person:=v_id; end if;
      end if;
      if v_person is null and v_qa is not null then
        select count(*),(array_agg(p.id))[1] into v_match_count,v_id from public.org_people p where p.designation=v_role and p.qa_employee_id=v_qa;
        if v_match_count=1 then v_person:=v_id; end if;
      end if;
      if v_person is null and v_mob is not null then
        select count(*),(array_agg(p.id))[1] into v_match_count,v_id from public.org_people p where p.designation=v_role and regexp_replace(coalesce(p.mobile,''),'\D','','g')=v_mob;
        if v_match_count=1 then v_person:=v_id; end if;
      end if;
      if v_person is null then
        select count(*),(array_agg(p.id))[1] into v_match_count,v_id from public.org_people p where p.designation=v_role
          and lower(regexp_replace(trim(p.employee_name),'\s+',' ','g'))=lower(regexp_replace(v_name,'\s+',' ','g'))
          and coalesce(lower(p.state_raw),'')=coalesce(lower(v_state),'') and coalesce(lower(p.market_raw),'')=coalesce(lower(v_market),'')
          ;
        if v_match_count=1 then v_person:=v_id; end if;
      end if;
      -- Link existing promoter accounts by exact mobile first, then exact employee name only when unique.
      v_user:=null;
      if v_role='PROMOTER' then
        select au.id into v_user from public.app_users au join public.promoters pr on pr.user_id=au.id
        where au.role='promoter' and v_mob is not null and regexp_replace(coalesce(au.mobile,''),'\D','','g')=v_mob limit 1;
        if v_user is null then
        select (array_agg(au.id))[1] into v_user from public.app_users au join public.promoters pr on pr.user_id=au.id
          where au.role='promoter' and lower(regexp_replace(trim(au.full_name),'\s+',' ','g'))=lower(regexp_replace(v_name,'\s+',' ','g'))
          having count(*)=1;
        end if;
      end if;
      if v_person is not null and v_user is not null then
        update public.org_people set auth_user_id=coalesce(auth_user_id,v_user) where id=v_person;
      end if;
      insert into public.org_inventory(source_run_key,source_row,person_id,employee_name,designation,state_raw,market_raw,area_raw,mobile,fas_id,qa_employee_id,snack5_initial,snack10_initial)
      values(p_run_key,v_source_row,v_person,v_name,v_role,v_state,v_market,v_area,nullif(trim(r->>'mobile'),''),v_fas,v_qa,v_qty5,v_qty10)
      on conflict do nothing;
      if v_person is not null and v_user is not null and v_role='PROMOTER' then
        -- First import only. Never modify an existing balance or its ledger on re-import.
        for v_prize,v_qty in select * from (values(v_prize5,v_qty5),(v_prize10,v_qty10)) x(prize_id,qty) loop
          if v_qty>0 then
            insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved) values(v_user,v_prize,v_qty,0)
            on conflict(promoter_id,prize_id) do nothing returning promoter_id into v_seeded;
            if v_seeded is not null then
              insert into public.inventory_movements(promoter_id,prize_id,movement_type,qty,on_hand_after,performed_by,reference,note)
              values(v_user,v_prize,'issue',v_qty,v_qty,auth.uid(),p_run_key,'Initial source-file inventory allocation');
            end if;
            v_seeded:=null;
          end if;
        end loop;
      end if;
      v_inv:=v_inv+1;
    end loop;
    insert into public.org_import_runs(run_key,master_rows,inventory_rows,imported_by) values(p_run_key,v_count,v_inv,auth.uid());
  end if;
  perform public.write_audit('ORG_MASTER_IMPORT','org_import_runs',p_run_key,jsonb_build_object('master_rows',v_count,'inventory_rows',v_inv,'inventory_applied',not v_existing));
  return jsonb_build_object('master_rows',v_count,'inventory_rows',case when v_existing then 0 else v_inv end,'inventory_already_imported',v_existing);
end $$;
