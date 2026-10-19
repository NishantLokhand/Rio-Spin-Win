alter table public.org_people add column if not exists territory_id uuid references public.territories(id);

create or replace function public.get_field_user_metrics()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare actor public.app_users; result jsonb;
begin
  actor:=public._require_staff();
  select coalesce(jsonb_agg(r),'[]'::jsonb) into result from (
    select a.id as key,(a.created_at at time zone 'Asia/Kolkata')::date as account_date,
      coalesce((select jsonb_agg(d.biz_date order by d.biz_date) from (
        select distinct sp.biz_date from public.spins sp where sp.promoter_id=a.id
          and sp.biz_date<=(now() at time zone 'Asia/Kolkata')::date
      ) d),'[]'::jsonb) as spin_dates,
      stock.snack5_received,stock.snack5_remaining,stock.snack5_used_pct,
      stock.snack10_received,stock.snack10_remaining,stock.snack10_used_pct
    from public.app_users a join public.promoters p on p.user_id=a.id
    cross join lateral (
      select max(received) filter(where code='SNACK5') as snack5_received,
        max(on_hand) filter(where code='SNACK5') as snack5_remaining,
        max(used_pct) filter(where code='SNACK5') as snack5_used_pct,
        max(received) filter(where code='SNACK10') as snack10_received,
        max(on_hand) filter(where code='SNACK10') as snack10_remaining,
        max(used_pct) filter(where code='SNACK10') as snack10_used_pct
      from (
        select pr.code,inv.on_hand,received.qty as received,
          case when received.qty>0 and inv.on_hand<=received.qty
            then round(100.0*(received.qty-inv.on_hand)/received.qty,2) end as used_pct
        from public.prizes pr
        left join public.promoter_inventory inv on inv.promoter_id=a.id and inv.prize_id=pr.id
        cross join lateral (select sum(m.qty) as qty from public.inventory_movements m
          where m.promoter_id=a.id and m.prize_id=pr.id and m.qty>0) received
        where pr.code in ('SNACK5','SNACK10')
      ) balances
    ) stock
    where a.role='promoter' and (actor.role='admin' or p.supervisor_id=actor.id)
  ) r;
  return result;
end $$;
revoke all on function public.get_field_user_metrics() from public,anon;
grant execute on function public.get_field_user_metrics() to authenticated;

create or replace function public.update_field_user(p_user_id uuid,p_values jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare a public.app_users; person public.org_people; st public.states; role_name text;
  terr uuid; supervisor uuid; tse uuid; mer uuid;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  select * into a from public.app_users where id=p_user_id and role='promoter' for update;
  if a.id is null then raise exception 'FIELD_USER_NOT_FOUND'; end if;
  select * into person from public.org_people where auth_user_id=p_user_id for update;
  if person.id is null then raise exception 'ORG_PROFILE_MISSING'; end if;
  role_name:=p_values->>'designation';
  if role_name not in ('PROMOTER','TSE','MER') or role_name is null then raise exception 'INVALID_FIELD_ROLE'; end if;
  if nullif(btrim(p_values->>'full_name'),'') is null then raise exception 'NAME_REQUIRED'; end if;
  select * into st from public.states where id=(p_values->>'home_state_id')::uuid and code in ('MH','UP');
  if st.id is null then raise exception 'FIELD_STATE_REQUIRED'; end if;
  terr:=nullif(p_values->>'territory_id','')::uuid;
  if terr is not null and not exists(select 1 from public.territories where id=terr and state_id=st.id) then
    raise exception 'TERRITORY_STATE_MISMATCH'; end if;
  supervisor:=nullif(p_values->>'supervisor_id','')::uuid;
  if supervisor is not null and not exists(select 1 from public.app_users where id=supervisor and role='supervisor' and is_active) then raise exception 'INVALID_SUPERVISOR'; end if;
  if role_name='PROMOTER' then
    tse:=nullif(p_values->>'mapped_tse_id','')::uuid; mer:=nullif(p_values->>'mapped_mer_id','')::uuid;
    if tse is not null and not exists(select 1 from public.org_people where id=tse and designation='TSE' and active) then raise exception 'INVALID_TSE'; end if;
    if mer is not null and not exists(select 1 from public.org_people where id=mer and designation='MER' and active) then raise exception 'INVALID_MER'; end if;
  end if;
  update public.app_users set full_name=btrim(p_values->>'full_name'),mobile=nullif(btrim(p_values->>'mobile'),'') where id=p_user_id;
  update public.promoters set promoter_code=btrim(p_values->>'promoter_code'),
    promoter_type=(p_values->>'promoter_type')::public.promoter_type,
    agency_name=nullif(btrim(p_values->>'agency_name'),''),supervisor_id=supervisor,home_state_id=st.id where user_id=p_user_id;
  update public.org_people set employee_name=btrim(p_values->>'full_name'),mobile=nullif(btrim(p_values->>'mobile'),''),
    designation=role_name,state_raw=st.name,market_override=coalesce(p_values->>'market',''),
    area_override=coalesce(p_values->>'area',''),beat_override=coalesce(p_values->'beats','[]'::jsonb),
    territory_id=terr,mapped_tse_id=tse,mapped_mer_id=mer,updated_at=now() where id=person.id;
  perform public.write_audit('FIELD_USER_UPDATED','app_users',p_user_id::text,p_values);
end $$;
revoke all on function public.update_field_user(uuid,jsonb) from public,anon;
grant execute on function public.update_field_user(uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
