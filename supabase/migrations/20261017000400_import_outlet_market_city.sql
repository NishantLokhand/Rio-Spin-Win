-- MARKET is City metadata, not part of an outlet's stable identity.
alter table public.global_outlet_import_staging add column if not exists city text;
alter table public.outlet_search_master add column if not exists city text;

create or replace function public.import_global_outlet_batch(p_import_id uuid,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_run public.global_outlet_import_runs; r jsonb; v_state text; v_name text; v_route text; v_area text;
  v_license text; v_address text; v_city text; v_occurrence integer; v_hash text; v_canonical text; v_count integer:=0;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if p_rows is null or jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'INVALID_IMPORT_BATCH'; end if;
  select * into v_run from public.global_outlet_import_runs where id=p_import_id for update;
  if v_run.id is null or v_run.created_by<>auth.uid() then raise exception 'IMPORT_RUN_NOT_FOUND'; end if;
  if v_run.status<>'staging' then return jsonb_build_object('accepted',0,'status',v_run.status); end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    v_state:=upper(coalesce(nullif(btrim(r->>'state_code'),''),''));
    if v_state not in ('UP','MH') then raise exception 'INVALID_OUTLET_STATE'; end if;
    v_name:=nullif(btrim(regexp_replace(normalize(coalesce(r->>'outlet_name',''),NFKC),'\s+',' ','g')),'');
    v_route:=btrim(regexp_replace(normalize(coalesce(r->>'route',''),NFKC),'\s+',' ','g'));
    v_area:=btrim(regexp_replace(normalize(coalesce(r->>'area',''),NFKC),'\s+',' ','g'));
    v_license:=btrim(regexp_replace(normalize(coalesce(r->>'license_no',''),NFKC),'\s+',' ','g'));
    v_address:=btrim(regexp_replace(normalize(coalesce(r->>'address',''),NFKC),'\s+',' ','g'));
    v_city:=nullif(btrim(regexp_replace(coalesce(r->>'city',''), '\s+', ' ', 'g')),'');
    v_occurrence:=coalesce((r->>'duplicate_occurrence')::integer,0);
    if v_name is null or v_occurrence<1 then raise exception 'INVALID_OUTLET_ROW'; end if;
    v_canonical:=v_state||chr(31)||lower(v_name)||chr(31)||lower(v_route)||chr(31)||lower(v_area)||chr(31)||lower(v_license)||chr(31)||lower(v_address);
    v_hash:=encode(extensions.digest(convert_to(v_canonical,'UTF8'),'sha256'),'hex');
    insert into public.global_outlet_import_staging(import_id,source_row_hash,duplicate_occurrence,state_code,
      outlet_name,route,area,license_no,address,normalized_outlet_name,normalized_license_no,normalized_address,city)
    values(p_import_id,v_hash,v_occurrence,v_state,v_name,v_route,v_area,v_license,v_address,
      public.normalize_outlet_search_text(v_name),public.normalize_outlet_search_text(v_license),public.normalize_outlet_search_text(v_address),v_city)
    on conflict(import_id,source_row_hash,duplicate_occurrence) do update set
      outlet_name=excluded.outlet_name,route=excluded.route,area=excluded.area,license_no=excluded.license_no,
      address=excluded.address,city=excluded.city,normalized_outlet_name=excluded.normalized_outlet_name,
      normalized_license_no=excluded.normalized_license_no,normalized_address=excluded.normalized_address;
    v_count:=v_count+1;
  end loop;
  return jsonb_build_object('accepted',v_count,'status','staging');
end $$;

create or replace function public.finalize_global_outlet_import(p_import_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_run public.global_outlet_import_runs; r record; v_state_id uuid; v_territory_id uuid;
  v_outlet_id uuid; v_existing_count integer; v_existing_id uuid; v_code text;
  v_created integer:=0; v_matched integer:=0; v_directory integer:=0; v_count integer; v_remaining integer;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  select * into v_run from public.global_outlet_import_runs where id=p_import_id for update;
  if v_run.id is null or v_run.created_by<>auth.uid() then raise exception 'IMPORT_RUN_NOT_FOUND'; end if;
  if v_run.status='published' then return jsonb_build_object('status','published','rows',v_run.imported_rows,
    'created_outlets',v_run.created_outlets,'matched_outlets',v_run.matched_outlets); end if;
  if v_run.status='staging' then
    select count(*) into v_count from public.global_outlet_import_staging where import_id=p_import_id;
    if v_count<>v_run.expected_rows then
      raise exception 'GLOBAL_OUTLET_IMPORT_INCOMPLETE' using detail=format('Expected %s rows, staged %s.',v_run.expected_rows,v_count);
    end if;
    if exists (
      select d.operational_outlet_id from public.global_outlet_import_staging g
      join public.outlet_search_master d using(source_row_hash,duplicate_occurrence)
      where g.import_id=p_import_id and g.city is not null and d.operational_outlet_id is not null
      group by d.operational_outlet_id having count(distinct g.city)>1
    ) then raise exception 'CONFLICTING_OUTLET_CITIES'; end if;
    update public.global_outlet_import_runs set status='processing' where id=p_import_id;
  end if;

  for r in select * from public.global_outlet_import_staging where import_id=p_import_id
    order by state_code,source_row_hash,duplicate_occurrence limit 400 loop
    select id into v_state_id from public.states where upper(code)=r.state_code
      or public.normalize_outlet_search_text(name)=case r.state_code when 'UP' then 'uttarpradesh' else 'maharashtra' end
      order by (upper(code)=r.state_code) desc limit 1;
    if v_state_id is null then
      insert into public.states(code,name) values(r.state_code,case r.state_code when 'UP' then 'Uttar Pradesh' else 'Maharashtra' end)
        returning id into v_state_id;
    end if;
    select id into v_territory_id from public.territories where state_id=v_state_id and code='GLOBAL-OUTLETS-'||r.state_code;
    if v_territory_id is null then
      insert into public.territories(state_id,code,name) values(v_state_id,'GLOBAL-OUTLETS-'||r.state_code,'Global outlet directory')
        returning id into v_territory_id;
    end if;

    select d.operational_outlet_id into v_outlet_id from public.outlet_search_master d
      where d.source_row_hash=r.source_row_hash and d.duplicate_occurrence=r.duplicate_occurrence;
    if v_outlet_id is null then
      select count(*) into v_existing_count
      from public.outlets o
      left join public.tses t on t.id=o.tse_id
      left join public.territories ot on ot.id=coalesce(o.territory_id,t.territory_id)
      left join public.states os on os.id=coalesce(o.state_id,ot.state_id)
      where o.status='active' and os.id=v_state_id
        and public.normalize_outlet_search_text(o.name)=r.normalized_outlet_name
        and (r.area='' or public.normalize_outlet_search_text(coalesce(o.area,''))=public.normalize_outlet_search_text(r.area))
        and (r.route='' or public.normalize_outlet_search_text(coalesce(o.beat,''))=public.normalize_outlet_search_text(r.route));
      if v_existing_count=1 then
        select o.id into v_existing_id
        from public.outlets o
        left join public.tses t on t.id=o.tse_id
        left join public.territories ot on ot.id=coalesce(o.territory_id,t.territory_id)
        left join public.states os on os.id=coalesce(o.state_id,ot.state_id)
        where o.status='active' and os.id=v_state_id
          and public.normalize_outlet_search_text(o.name)=r.normalized_outlet_name
          and (r.area='' or public.normalize_outlet_search_text(coalesce(o.area,''))=public.normalize_outlet_search_text(r.area))
          and (r.route='' or public.normalize_outlet_search_text(coalesce(o.beat,''))=public.normalize_outlet_search_text(r.route))
        limit 1;
        v_outlet_id:=v_existing_id; v_matched:=v_matched+1;
        update public.outlets set state_id=coalesce(state_id,v_state_id),territory_id=coalesce(territory_id,v_territory_id),
          area=coalesce(nullif(area,''),nullif(r.area,'')),beat=coalesce(nullif(beat,''),nullif(r.route,'')),updated_at=now()
          where id=v_outlet_id;
      else
        v_code:=r.state_code||'-OUT-'||substr(r.source_row_hash,1,16)||'-'||r.duplicate_occurrence::text;
        select id into v_outlet_id from public.outlets where outlet_code=v_code;
        if v_outlet_id is null then
          insert into public.outlets(tse_id,outlet_code,name,area,beat,status,source,state_id,territory_id)
          values(null,v_code,r.outlet_name,nullif(r.area,''),nullif(r.route,''),'active','upload',v_state_id,v_territory_id)
          returning id into v_outlet_id;
          v_created:=v_created+1;
        end if;
      end if;
    end if;

    if r.city is not null then
      update public.outlets set city=r.city,updated_at=now()
        where id=v_outlet_id and city is distinct from r.city;
      -- Fill only blank geography. Preserve recorded cities and all sale metrics.
      update public.sales set outlet_city=r.city
        where outlet_id=v_outlet_id and nullif(btrim(outlet_city),'') is null;
    end if;

    insert into public.outlet_search_master(source_row_hash,duplicate_occurrence,state_code,outlet_name,license_no,address,
      normalized_outlet_name,normalized_license_no,normalized_address,is_active,imported_at,route,area,operational_outlet_id,city)
    values(r.source_row_hash,r.duplicate_occurrence,r.state_code,r.outlet_name,nullif(r.license_no,''),nullif(r.address,''),
      r.normalized_outlet_name,r.normalized_license_no,r.normalized_address,true,now(),nullif(r.route,''),nullif(r.area,''),v_outlet_id,r.city)
    on conflict(source_row_hash,duplicate_occurrence) do update set state_code=excluded.state_code,
      outlet_name=excluded.outlet_name,license_no=coalesce(excluded.license_no,public.outlet_search_master.license_no),
      address=coalesce(excluded.address,public.outlet_search_master.address),normalized_outlet_name=excluded.normalized_outlet_name,
      normalized_license_no=excluded.normalized_license_no,normalized_address=coalesce(nullif(excluded.normalized_address,''),public.outlet_search_master.normalized_address),
      route=excluded.route,area=excluded.area,city=coalesce(excluded.city,public.outlet_search_master.city),operational_outlet_id=coalesce(public.outlet_search_master.operational_outlet_id,excluded.operational_outlet_id),
      is_active=true,imported_at=now();
    v_directory:=v_directory+1;
    delete from public.global_outlet_import_staging where import_id=p_import_id
      and source_row_hash=r.source_row_hash and duplicate_occurrence=r.duplicate_occurrence;
  end loop;
  select count(*) into v_remaining from public.global_outlet_import_staging where import_id=p_import_id;
  update public.global_outlet_import_runs set status=case when v_remaining=0 then 'published' else 'processing' end,
    imported_rows=imported_rows+v_directory,created_outlets=created_outlets+v_created,
    matched_outlets=matched_outlets+v_matched,published_at=case when v_remaining=0 then now() else null end
    where id=p_import_id returning * into v_run;
  if v_remaining>0 then
    return jsonb_build_object('status','processing','rows',v_run.imported_rows,'remaining',v_remaining,
      'created_outlets',v_run.created_outlets,'matched_outlets',v_run.matched_outlets);
  end if;
  perform public.write_audit('GLOBAL_OUTLET_IMPORT','outlet_search_master',p_import_id::text,
    jsonb_build_object('rows',v_run.imported_rows,'created_operational_outlets',v_run.created_outlets,'matched_existing_outlets',v_run.matched_outlets));
  return jsonb_build_object('status','published','rows',v_run.imported_rows,'created_outlets',v_run.created_outlets,'matched_outlets',v_run.matched_outlets);
end $$;

-- Filter and group on recorded outlet city; preserve historical sale snapshots.
create or replace function public.get_report_cities(p_state_id uuid default null,p_area text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare u public.app_users; result jsonb;
begin
  u:=public._require_staff();
  select coalesce(jsonb_agg(city order by city),'[]'::jsonb) into result
  from (
    select distinct city from (
      select m.city from public.outlet_search_master m
      join public.states st on st.code=m.state_code
      where u.role='admin' and m.is_active and (p_state_id is null or st.id=p_state_id) and (p_area is null or m.area=p_area)
      union
      select o.city from public.outlets o
      where u.role='admin' and (p_state_id is null or o.state_id=p_state_id) and (p_area is null or o.area=p_area)
      union
      select s.outlet_city from public.sales s
      where (p_state_id is null or s.state_id=p_state_id) and (p_area is null or s.outlet_area=p_area)
        and (u.role='admin' or s.promoter_id in (select user_id from public.promoters where supervisor_id=u.id))
    ) source where nullif(btrim(city),'') is not null
  ) citys;
  return result;
end $$;
revoke all on function public.get_report_cities(uuid,text) from public,anon;
grant execute on function public.get_report_cities(uuid,text) to authenticated;

notify pgrst,'reload schema';
