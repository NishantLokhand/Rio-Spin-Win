-- Organizational masters and safe, repeatable employee inventory import.
-- Source geography is preserved verbatim; this migration does not map Market/Area/Zone to Territory.

create table public.org_people (
  id uuid primary key default gen_random_uuid(),
  designation text not null check (designation in ('PROMOTER','TSE','MER','ASM')),
  employee_name text not null,
  mobile text,
  fas_id text,
  qa_employee_id text,
  source_key text not null unique,
  source_system text not null,
  source_ids jsonb not null default '{}'::jsonb,
  state_raw text,
  market_raw text,
  zone_raw text,
  area_raw text,
  beat_values jsonb not null default '[]'::jsonb,
  market_override text,
  area_override text,
  beat_override jsonb,
  active boolean not null default true,
  auth_user_id uuid unique references public.app_users(id) on delete set null,
  mapped_tse_id uuid references public.org_people(id),
  mapped_mer_id uuid references public.org_people(id),
  assignment_source text not null default 'manual' check (assignment_source in ('manual','source_import')),
  assignment_status text generated always as (
    case when designation <> 'PROMOTER' then 'NOT_APPLICABLE'
         when mapped_tse_id is not null and mapped_mer_id is not null then 'TSE_AND_MER_ASSIGNED'
         when mapped_tse_id is not null then 'TSE_ASSIGNED'
         when mapped_mer_id is not null then 'MER_ASSIGNED'
         else 'NO_TSE_OR_MER' end
  ) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (designation = 'PROMOTER' or (mapped_tse_id is null and mapped_mer_id is null))
);
create index org_people_role_geo_idx on public.org_people(designation, state_raw, market_raw, area_raw);
create index org_people_mobile_idx on public.org_people(mobile) where mobile is not null;

create table public.promoter_outlet_assignments (
  promoter_id uuid not null references public.org_people(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id),
  assigned_by uuid references public.app_users(id),
  assigned_at timestamptz not null default now(),
  active boolean not null default true,
  primary key (promoter_id, outlet_id)
);
create index promoter_outlet_assignments_outlet_idx on public.promoter_outlet_assignments(outlet_id) where active;

create table public.org_inventory (
  id uuid primary key default gen_random_uuid(),
  source_run_key text not null,
  person_id uuid references public.org_people(id),
  employee_name text not null,
  designation text not null check (designation in ('PROMOTER','TSE','MER','ASM')),
  state_raw text,
  market_raw text,
  area_raw text,
  mobile text,
  fas_id text,
  qa_employee_id text,
  snack5_initial int not null check (snack5_initial >= 0),
  snack10_initial int not null check (snack10_initial >= 0),
  imported_at timestamptz not null default now(),
  unique(source_run_key, designation, fas_id, qa_employee_id, mobile, employee_name)
);
create index org_inventory_person_idx on public.org_inventory(person_id);

create table public.org_inventory_adjustments (
  id uuid primary key default gen_random_uuid(),
  org_inventory_id uuid not null references public.org_inventory(id),
  prize_code text not null check (prize_code in ('SNACK5','SNACK10')),
  qty_delta int not null check (qty_delta <> 0),
  note text not null,
  performed_by uuid not null references public.app_users(id),
  created_at timestamptz not null default now()
);

create table public.org_import_runs (
  run_key text primary key,
  master_rows int not null default 0,
  inventory_rows int not null default 0,
  imported_by uuid references public.app_users(id),
  completed_at timestamptz not null default now()
);

alter table public.outlets add column if not exists beat text;
alter table public.org_people add column if not exists market_override text;
alter table public.org_people add column if not exists area_override text;
alter table public.org_people add column if not exists beat_override jsonb;
alter table public.sales add column if not exists promoter_market_snapshot text;
alter table public.sales add column if not exists promoter_area_snapshot text;
alter table public.sales add column if not exists promoter_beat_snapshot text;
alter table public.sales add column if not exists promoter_tse_snapshot text;
alter table public.sales add column if not exists promoter_mer_snapshot text;
alter table public.sales add column if not exists outlet_beat_snapshot text;

-- Extend the existing outlet importer to preserve an optional source Beat.
create or replace function public.import_outlets(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r jsonb; i int:=0; v_state uuid; v_terr uuid; v_tse uuid; v_ins int:=0; v_upd int:=0;
        v_err jsonb:='[]'::jsonb; v_exists boolean; v_status public.record_status;
begin
  perform public._require_admin();
  for r in select * from jsonb_array_elements(p_rows) loop
    i:=i+1;
    begin
      if coalesce(r->>'state','')='' or coalesce(r->>'territory','')='' or coalesce(r->>'tse_code','')=''
        or coalesce(r->>'outlet_code','')='' or coalesce(r->>'outlet_name','')='' then raise exception 'Missing required outlet columns'; end if;
      v_status:=case when lower(coalesce(r->>'status','active')) in ('inactive','n','no','0','closed') then 'inactive' else 'active' end;
      select id into v_state from public.states where lower(name)=lower(trim(r->>'state')) or lower(code)=lower(trim(r->>'state'));
      if v_state is null then
        insert into public.states(code,name) values(upper(left(regexp_replace(trim(r->>'state'),'[^A-Za-z]','','g'),3))||'-'||substr(gen_random_uuid()::text,1,4),trim(r->>'state')) returning id into v_state;
      end if;
      select id into v_terr from public.territories where state_id=v_state and (lower(name)=lower(trim(r->>'territory')) or lower(code)=lower(trim(r->>'territory')));
      if v_terr is null then
        insert into public.territories(state_id,code,name) values(v_state,upper(left(regexp_replace(trim(r->>'territory'),'[^A-Za-z]','','g'),4))||'-'||substr(gen_random_uuid()::text,1,4),trim(r->>'territory')) returning id into v_terr;
      end if;
      select id into v_tse from public.tses where lower(code)=lower(trim(r->>'tse_code'));
      if v_tse is null then
        insert into public.tses(territory_id,code,name) values(v_terr,trim(r->>'tse_code'),coalesce(nullif(trim(r->>'tse_name'),''),trim(r->>'tse_code'))) returning id into v_tse;
      else update public.tses set territory_id=v_terr,name=coalesce(nullif(trim(r->>'tse_name'),''),name) where id=v_tse; end if;
      select exists(select 1 from public.outlets where outlet_code=trim(r->>'outlet_code')) into v_exists;
      insert into public.outlets(tse_id,outlet_code,name,area,beat,city,distributor,status,source)
      values(v_tse,trim(r->>'outlet_code'),trim(r->>'outlet_name'),nullif(trim(r->>'area'),''),nullif(trim(r->>'beat'),''),nullif(trim(r->>'city'),''),nullif(trim(r->>'distributor'),''),v_status,'upload')
      on conflict(outlet_code) do update set tse_id=excluded.tse_id,name=excluded.name,area=excluded.area,beat=coalesce(excluded.beat,outlets.beat),
       city=excluded.city,distributor=excluded.distributor,status=excluded.status;
      if coalesce(v_exists,false) then v_upd:=v_upd+1; else v_ins:=v_ins+1; end if;
    exception when others then
      v_err:=v_err||jsonb_build_array(jsonb_build_object('row',i,'error',sqlerrm));
    end;
  end loop;
  perform public.write_audit('OUTLET_MASTER_UPLOAD','outlets',null,jsonb_build_object('rows',i,'inserted',v_ins,'updated',v_upd,'errors',jsonb_array_length(v_err)));
  return jsonb_build_object('rows',i,'inserted',v_ins,'updated',v_upd,'errors',v_err);
end $$;

alter table public.org_people enable row level security;
alter table public.promoter_outlet_assignments enable row level security;
alter table public.org_inventory enable row level security;
alter table public.org_inventory_adjustments enable row level security;
alter table public.org_import_runs enable row level security;
create policy org_people_admin_all on public.org_people for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy org_people_self_read on public.org_people for select to authenticated using (auth_user_id = auth.uid());
create policy org_people_supervisor_read on public.org_people for select to authenticated using (
 designation='PROMOTER' and exists(select 1 from public.promoters pr where pr.user_id=auth_user_id and pr.supervisor_id=auth.uid())
);
create policy promoter_outlet_admin_all on public.promoter_outlet_assignments for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy promoter_outlet_self_read on public.promoter_outlet_assignments for select to authenticated using (
 exists (select 1 from public.org_people p where p.id=promoter_id and p.auth_user_id=auth.uid())
);
create policy promoter_outlet_supervisor_read on public.promoter_outlet_assignments for select to authenticated using (
 exists(select 1 from public.org_people p join public.promoters pr on pr.user_id=p.auth_user_id where p.id=promoter_id and pr.supervisor_id=auth.uid())
);
create policy org_inventory_admin_read on public.org_inventory for select to authenticated using (public.is_admin());
create policy org_inventory_adjust_admin_all on public.org_inventory_adjustments for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy org_import_admin_read on public.org_import_runs for select to authenticated using (public.is_admin());
revoke all on public.org_people, public.promoter_outlet_assignments, public.org_inventory, public.org_import_runs from anon;
revoke all on public.org_inventory_adjustments from anon;
grant select, insert, update on public.org_people to authenticated;
grant select on public.promoter_outlet_assignments to authenticated;
grant select on public.org_inventory, public.org_import_runs to authenticated;
grant select on public.org_inventory_adjustments to authenticated;

-- Replace the original signed-in-users outlet policy with exact assigned-outlet scope.
drop policy if exists outlets_read on public.outlets;
create policy outlets_read on public.outlets for select to authenticated using (
  public.is_admin()
  or (public.my_role()='promoter' and exists(
      select 1 from public.org_people p join public.promoter_outlet_assignments a on a.promoter_id=p.id
      where p.auth_user_id=auth.uid() and p.active and a.outlet_id=outlets.id and a.active))
  or (public.my_role()='supervisor' and exists(
      select 1 from public.org_people p join public.promoter_outlet_assignments a on a.promoter_id=p.id
      join public.promoters pr on pr.user_id=p.auth_user_id
      where pr.supervisor_id=auth.uid() and p.active and a.outlet_id=outlets.id and a.active))
);

drop policy if exists tses_read on public.tses;
create policy tses_read on public.tses for select to authenticated using (
  public.is_admin()
  or (public.my_role()='promoter' and exists(
    select 1 from public.promoter_outlet_assignments a join public.org_people p on p.id=a.promoter_id
    join public.outlets o on o.id=a.outlet_id where p.auth_user_id=auth.uid() and p.active and a.active and o.tse_id=tses.id))
  or (public.my_role()='supervisor' and exists(
    select 1 from public.promoter_outlet_assignments a join public.org_people p on p.id=a.promoter_id
    join public.promoters pr on pr.user_id=p.auth_user_id join public.outlets o on o.id=a.outlet_id
    where pr.supervisor_id=auth.uid() and p.active and a.active and o.tse_id=tses.id))
);

create or replace function public.validate_org_assignment_roles() returns trigger language plpgsql set search_path=public as $$
begin
  if new.mapped_tse_id is not null and not exists(select 1 from public.org_people where id=new.mapped_tse_id and designation='TSE') then raise exception 'ASSIGNED_PERSON_NOT_TSE'; end if;
  if new.mapped_mer_id is not null and not exists(select 1 from public.org_people where id=new.mapped_mer_id and designation='MER') then raise exception 'ASSIGNED_PERSON_NOT_MER'; end if;
  return new;
end $$;
create trigger org_assignment_role_check before insert or update of mapped_tse_id,mapped_mer_id,designation on public.org_people for each row execute function public.validate_org_assignment_roles();

create or replace function public.audit_org_directory_change() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' and new.source_system='admin' then
    perform public.write_audit('ORG_PERSON_CREATED','org_people',new.id::text,jsonb_build_object('designation',new.designation,'employee_name',new.employee_name));
  elsif tg_op='UPDATE' and (old.mapped_tse_id is distinct from new.mapped_tse_id or old.mapped_mer_id is distinct from new.mapped_mer_id
    or old.auth_user_id is distinct from new.auth_user_id or old.active is distinct from new.active
    or old.market_override is distinct from new.market_override or old.area_override is distinct from new.area_override or old.beat_override is distinct from new.beat_override) then
    perform public.write_audit('ORG_ASSIGNMENT_CHANGED','org_people',new.id::text,jsonb_build_object(
      'mapped_tse_id',jsonb_build_array(old.mapped_tse_id,new.mapped_tse_id),'mapped_mer_id',jsonb_build_array(old.mapped_mer_id,new.mapped_mer_id),
      'auth_user_id',jsonb_build_array(old.auth_user_id,new.auth_user_id),'active',jsonb_build_array(old.active,new.active),
      'market_override',jsonb_build_array(old.market_override,new.market_override),'area_override',jsonb_build_array(old.area_override,new.area_override),
      'beat_override',jsonb_build_array(old.beat_override,new.beat_override)));
  end if;
  return new;
end $$;
create trigger org_directory_audit after insert or update on public.org_people for each row execute function public.audit_org_directory_change();

create or replace function public.audit_promoter_outlet_change() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='DELETE' then
    perform public.write_audit('PROMOTER_OUTLET_UNASSIGNED','promoter_outlet_assignments',old.promoter_id::text||':'||old.outlet_id::text,jsonb_build_object('promoter_id',old.promoter_id,'outlet_id',old.outlet_id,'active',old.active));
    return old;
  else
    perform public.write_audit('PROMOTER_OUTLET_ASSIGNED','promoter_outlet_assignments',new.promoter_id::text||':'||new.outlet_id::text,jsonb_build_object('promoter_id',new.promoter_id,'outlet_id',new.outlet_id,'active',new.active));
    return new;
  end if;
end $$;
create trigger promoter_outlet_audit after insert or update or delete on public.promoter_outlet_assignments for each row execute function public.audit_promoter_outlet_change();

-- Import uses source_key as identity. Existing manual assignments and auth links are never overwritten.
create or replace function public.import_org_master_inventory(p_master jsonb, p_inventory jsonb, p_run_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r jsonb; v_id uuid; v_count int:=0; v_inv int:=0; v_prize5 uuid; v_prize10 uuid; v_user uuid; v_person uuid;
        v_mob text; v_fas text; v_qa text; v_name text; v_role text; v_state text; v_market text; v_area text;
        v_qty5 int; v_qty10 int; v_existing boolean; v_prize uuid; v_qty int; v_seeded uuid; v_match_count int;
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
      insert into public.org_inventory(source_run_key,person_id,employee_name,designation,state_raw,market_raw,area_raw,mobile,fas_id,qa_employee_id,snack5_initial,snack10_initial)
      values(p_run_key,v_person,v_name,v_role,v_state,v_market,v_area,nullif(trim(r->>'mobile'),''),v_fas,v_qa,v_qty5,v_qty10)
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

create or replace function public.get_promoter_outlets()
returns table(id uuid,outlet_code text,name text,area text,city text,tse_id uuid,beat text)
language plpgsql stable security definer set search_path=public as $$
begin
  perform public._require_promoter();
  return query select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
  from public.org_people p join public.promoter_outlet_assignments a on a.promoter_id=p.id and a.active
  join public.outlets o on o.id=a.outlet_id and o.status='active'
  where p.auth_user_id=auth.uid() and p.active order by o.name;
end $$;

create or replace function public.set_promoter_outlets(p_promoter_id uuid,p_outlet_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_outlet uuid;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if not exists(select 1 from public.org_people where id=p_promoter_id and designation='PROMOTER') then raise exception 'PROMOTER_NOT_FOUND'; end if;
  foreach v_outlet in array coalesce(p_outlet_ids,'{}'::uuid[]) loop
    if not exists(select 1 from public.outlets where id=v_outlet and status='active') then raise exception 'OUTLET_NOT_ACTIVE'; end if;
  end loop;
  delete from public.promoter_outlet_assignments where promoter_id=p_promoter_id and not (outlet_id=any(coalesce(p_outlet_ids,'{}'::uuid[])));
  insert into public.promoter_outlet_assignments(promoter_id,outlet_id,assigned_by,active)
  select p_promoter_id,ids.outlet_id,auth.uid(),true from unnest(coalesce(p_outlet_ids,'{}'::uuid[])) as ids(outlet_id)
  on conflict(promoter_id,outlet_id) do update set assigned_by=excluded.assigned_by,assigned_at=now(),active=true;
  return jsonb_build_object('assigned',coalesce(cardinality(p_outlet_ids),0));
end $$;

create or replace function public.adjust_org_inventory(p_inventory_id uuid,p_prize_code text,p_qty_delta int,p_note text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.org_inventory; v_prize uuid; v_user uuid;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if p_qty_delta=0 or nullif(trim(p_note),'') is null then raise exception 'INVALID_ADJUSTMENT'; end if;
  select * into r from public.org_inventory where id=p_inventory_id for update;
  if r.id is null then raise exception 'INVENTORY_ROW_NOT_FOUND'; end if;
  select id into v_prize from public.prizes where code=p_prize_code and p_prize_code in ('SNACK5','SNACK10');
  if v_prize is null then raise exception 'PRIZE_NOT_FOUND'; end if;
  if not (r.designation='PROMOTER' and r.person_id is not null and exists(select 1 from public.org_people where id=r.person_id and auth_user_id is not null)) then
    if p_prize_code='SNACK5' and r.snack5_initial+coalesce((select sum(qty_delta) from public.org_inventory_adjustments where org_inventory_id=r.id and prize_code='SNACK5'),0)+p_qty_delta<0
      then raise exception 'INSUFFICIENT_STOCK'; end if;
    if p_prize_code='SNACK10' and r.snack10_initial+coalesce((select sum(qty_delta) from public.org_inventory_adjustments where org_inventory_id=r.id and prize_code='SNACK10'),0)+p_qty_delta<0
      then raise exception 'INSUFFICIENT_STOCK'; end if;
  end if;
  if r.designation='PROMOTER' and r.person_id is not null then
    select auth_user_id into v_user from public.org_people where id=r.person_id;
    if v_user is not null then perform public.adjust_stock(v_user,v_prize,'adjustment',p_qty_delta,p_note,'org-inventory:'||r.id::text); end if;
  end if;
  insert into public.org_inventory_adjustments(org_inventory_id,prize_code,qty_delta,note,performed_by)
  values(r.id,p_prize_code,p_qty_delta,trim(p_note),auth.uid());
  perform public.write_audit('ORG_STOCK_ADJUSTMENT','org_inventory',r.id::text,jsonb_build_object('prize',p_prize_code,'qty_delta',p_qty_delta,'note',p_note));
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.link_org_promoter(p_person_id uuid,p_user_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.org_people; u public.app_users; r record; v_prize uuid; v_qty int; v_seeded uuid;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  select * into p from public.org_people where id=p_person_id and designation='PROMOTER' for update;
  select * into u from public.app_users where id=p_user_id and role='promoter';
  if p.id is null or u.id is null then raise exception 'PROMOTER_LINK_INVALID'; end if;
  update public.org_people set auth_user_id=p_user_id,updated_at=now() where id=p_person_id;
  for r in select * from public.org_inventory where person_id=p_person_id loop
    for v_prize,v_qty in select pr.id,
      case when pr.code='SNACK5' then r.snack5_initial+coalesce((select sum(qty_delta) from public.org_inventory_adjustments a where a.org_inventory_id=r.id and a.prize_code='SNACK5'),0)
           when pr.code='SNACK10' then r.snack10_initial+coalesce((select sum(qty_delta) from public.org_inventory_adjustments a where a.org_inventory_id=r.id and a.prize_code='SNACK10'),0) end
      from public.prizes pr where pr.code in ('SNACK5','SNACK10') loop
      if v_qty>0 then
        insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved) values(p_user_id,v_prize,v_qty,0)
          on conflict(promoter_id,prize_id) do nothing returning promoter_id into v_seeded;
        if v_seeded is not null then
          insert into public.inventory_movements(promoter_id,prize_id,movement_type,qty,on_hand_after,performed_by,reference,note)
          values(p_user_id,v_prize,'issue',v_qty,v_qty,auth.uid(),'org-link:'||p_person_id::text,'Initial source allocation linked to promoter account');
        end if;
        v_seeded:=null;
      end if;
    end loop;
  end loop;
  perform public.write_audit('ORG_PROMOTER_LINK','org_people',p_person_id::text,jsonb_build_object('auth_user_id',p_user_id));
  return jsonb_build_object('ok',true);
end $$;

-- Capture organizational labels in the immutable-at-sale snapshot fields.
create or replace function public.snapshot_org_assignment_on_sale() returns trigger language plpgsql security definer set search_path=public as $$
declare v_person uuid;
begin
  select id into v_person from public.org_people p where p.auth_user_id=new.promoter_id and p.designation='PROMOTER' and p.active;
  if v_person is null then raise exception 'ORG_PROFILE_MISSING' using hint='Ask an administrator to link your organizational promoter record.'; end if;
  if not exists (select 1 from public.promoter_outlet_assignments a where a.promoter_id=v_person and a.outlet_id=new.outlet_id and a.active) then
    raise exception 'OUTLET_NOT_ASSIGNED' using hint='This promoter is not assigned to the selected outlet.';
  end if;
  select coalesce(p.market_override,p.market_raw),coalesce(p.area_override,p.area_raw),coalesce(p.beat_override->>0,p.beat_values->>0),t.employee_name,m.employee_name,o.beat
    into new.promoter_market_snapshot,new.promoter_area_snapshot,new.promoter_beat_snapshot,new.promoter_tse_snapshot,new.promoter_mer_snapshot,new.outlet_beat_snapshot
  from public.org_people p left join public.org_people t on t.id=p.mapped_tse_id left join public.org_people m on m.id=p.mapped_mer_id
  left join public.outlets o on o.id=new.outlet_id
  where p.auth_user_id=new.promoter_id;
  return new;
end $$;
drop trigger if exists sales_org_assignment_snapshot on public.sales;
create trigger sales_org_assignment_snapshot before insert on public.sales for each row execute function public.snapshot_org_assignment_on_sale();

create or replace function public.validate_promoter_session_outlet() returns trigger language plpgsql security definer set search_path=public as $$
declare v_person uuid;
begin
  select id into v_person from public.org_people p where p.auth_user_id=new.promoter_id and p.designation='PROMOTER' and p.active;
  if v_person is null then raise exception 'ORG_PROFILE_MISSING' using hint='Ask an administrator to link your organizational promoter record.'; end if;
  if not exists (select 1 from public.promoter_outlet_assignments a where a.promoter_id=v_person and a.outlet_id=new.outlet_id and a.active) then
    raise exception 'OUTLET_NOT_ASSIGNED' using hint='This promoter is not assigned to the selected outlet.';
  end if;
  return new;
end $$;
drop trigger if exists promoter_session_outlet_access on public.promoter_sessions;
create trigger promoter_session_outlet_access before insert or update of outlet_id on public.promoter_sessions for each row execute function public.validate_promoter_session_outlet();

revoke all on function public.import_org_master_inventory(jsonb,jsonb,text), public.get_promoter_outlets(), public.set_promoter_outlets(uuid,uuid[]), public.adjust_org_inventory(uuid,text,int,text), public.link_org_promoter(uuid,uuid) from public,anon;
grant execute on function public.import_org_master_inventory(jsonb,jsonb,text), public.get_promoter_outlets(), public.set_promoter_outlets(uuid,uuid[]), public.adjust_org_inventory(uuid,text,int,text), public.link_org_promoter(uuid,uuid) to authenticated;

