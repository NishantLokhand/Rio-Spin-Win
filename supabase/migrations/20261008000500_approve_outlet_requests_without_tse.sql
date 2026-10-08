-- Outlet requests under global access are not owned by a TSE. On approval,
-- derive the requester's state, create the outlet in that state's global
-- territory, and publish it to the global search directory.

create or replace function public.review_outlet_request(
  p_request_id uuid,
  p_approve boolean,
  p_tse_id uuid default null,
  p_outlet_code text default null,
  p_note text default null,
  p_name text default null,
  p_area text default null,
  p_city text default null,
  p_distributor text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  u public.app_users;
  rq public.outlet_requests;
  v_outlet uuid;
  v_code text;
  v_state_raw text;
  v_state_code text;
  v_state_id uuid;
  v_territory_id uuid;
  v_directory_hash text;
  v_name text;
  v_area text;
  v_city text;
begin
  u := public._require_staff();
  if u.role='supervisor' and not u.can_approve_outlets then
    raise exception 'NOT_AUTHORISED' using hint='You are not authorised to approve outlets.';
  end if;

  select * into rq from public.outlet_requests where id=p_request_id for update;
  if rq.id is null or not public.can_see_promoter(rq.promoter_id) then raise exception 'REQUEST_NOT_FOUND'; end if;
  if rq.status<>'pending' then raise exception 'REQUEST_ALREADY_REVIEWED'; end if;

  if p_approve then
    select p.state_raw into v_state_raw
    from public.org_people p
    where p.auth_user_id=rq.promoter_id and p.active
      and p.designation in ('PROMOTER','MER','TSE')
    order by case p.designation when 'PROMOTER' then 1 when 'MER' then 2 else 3 end,p.updated_at desc
    limit 1;

    v_state_code := case public.normalize_outlet_search_text(coalesce(v_state_raw,''))
      when 'up' then 'UP'
      when 'uttarpradesh' then 'UP'
      when 'mh' then 'MH'
      when 'maharashtra' then 'MH'
      else null
    end;
    if v_state_code is null then
      raise exception 'REQUESTER_STATE_REQUIRED'
        using hint='The requester needs an active linked profile with Uttar Pradesh or Maharashtra as the source state.';
    end if;

    insert into public.states(code,name)
    values(v_state_code,case v_state_code when 'UP' then 'Uttar Pradesh' else 'Maharashtra' end)
    on conflict(code) do update set name=excluded.name
    returning id into v_state_id;

    insert into public.territories(state_id,code,name)
    values(v_state_id,'GLOBAL-OUTLETS-'||v_state_code,'Global outlet directory')
    on conflict(code) do update set state_id=excluded.state_id,name=excluded.name
    returning id into v_territory_id;

    v_name := coalesce(nullif(btrim(p_name),''),rq.outlet_name);
    v_area := coalesce(nullif(btrim(p_area),''),rq.area);
    v_city := coalesce(nullif(btrim(p_city),''),rq.city);
    v_code := coalesce(nullif(btrim(p_outlet_code),''),nullif(btrim(rq.ref_code),''),
      'NEW-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)));
    if exists(select 1 from public.outlets where outlet_code=v_code) then raise exception 'OUTLET_CODE_EXISTS'; end if;

    insert into public.outlets(tse_id,state_id,territory_id,outlet_code,name,area,city,distributor,source)
    values(null,v_state_id,v_territory_id,v_code,v_name,v_area,v_city,p_distributor,'request')
    returning id into v_outlet;

    v_directory_hash := encode(extensions.digest(convert_to('OUTLET-REQUEST:'||rq.id::text,'UTF8'),'sha256'),'hex');
    insert into public.outlet_search_master(
      source_row_hash,duplicate_occurrence,state_code,outlet_name,license_no,address,
      normalized_outlet_name,normalized_license_no,normalized_address,is_active,imported_at,
      route,area,operational_outlet_id
    ) values (
      v_directory_hash,1,v_state_code,v_name,null,null,
      public.normalize_outlet_search_text(v_name),'','',true,now(),null,v_area,v_outlet
    );
  end if;

  update public.outlet_requests
  set status=case when p_approve then 'approved'::public.request_status else 'rejected'::public.request_status end,
      reviewed_by=u.id,reviewed_at=now(),review_note=p_note,outlet_id=v_outlet
  where id=rq.id;

  perform public.write_audit(case when p_approve then 'OUTLET_REQUEST_APPROVED' else 'OUTLET_REQUEST_REJECTED' end,
    'outlet_requests',rq.id::text,jsonb_build_object('outlet_id',v_outlet,'outlet_code',v_code,
      'state_code',v_state_code,'tse_id',null,'note',p_note));
  return jsonb_build_object('ok',true,'outlet_id',v_outlet,'outlet_code',v_code,'state_code',v_state_code);
end;
$$;

comment on function public.review_outlet_request(uuid,boolean,uuid,text,text,text,text,text,text) is
  'Approves requested outlets without TSE ownership; derives state from the requester profile and publishes to global outlet search.';

notify pgrst,'reload schema';
