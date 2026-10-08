-- Global UP + Maharashtra outlet directory. The migration keeps historical
-- outlet IDs and sale/spin records, deactivates outlet-person access links,
-- and lets every field user search the active operational outlet directory.
alter table public.outlet_search_master
  drop constraint if exists outlet_search_master_state_code_check;
alter table public.outlet_search_master
  add constraint outlet_search_master_state_code_check check (state_code in ('UP','MH'));
alter table public.outlet_search_master
  add column if not exists route text,
  add column if not exists area text,
  add column if not exists operational_outlet_id uuid references public.outlets(id) on delete set null;

-- Preserve outlet geography before removing operational TSE ownership. Sales
-- continue to use state and territory for campaign selection and reporting.
with derived_geography as (
  select o.id,coalesce(o.state_id,direct_territory.state_id,tse_territory.state_id) state_id,
    coalesce(o.territory_id,tse_territory.id) territory_id
  from public.outlets o
  left join public.territories direct_territory on direct_territory.id=o.territory_id
  left join public.tses t on t.id=o.tse_id
  left join public.territories tse_territory on tse_territory.id=t.territory_id
)
update public.outlets o set state_id=g.state_id,territory_id=g.territory_id,updated_at=now()
from derived_geography g where o.id=g.id and (o.state_id is distinct from g.state_id or o.territory_id is distinct from g.territory_id);

insert into public.territories(state_id,code,name)
select distinct o.state_id,'GLOBAL-OUTLETS-'||s.code,'Global outlet directory'
from public.outlets o join public.states s on s.id=o.state_id
where o.status='active' and o.territory_id is null and o.state_id is not null
on conflict(code) do nothing;

update public.outlets o set territory_id=t.id,updated_at=now()
from public.states s join public.territories t on t.state_id=s.id
where o.state_id=s.id and o.status='active' and o.territory_id is null
  and t.code='GLOBAL-OUTLETS-'||s.code;

do $$
declare v_missing integer;
begin
  select count(*) into v_missing from public.outlets o
  left join public.territories t on t.id=o.territory_id
  where o.status='active' and (o.state_id is null or o.territory_id is null or t.state_id is distinct from o.state_id);
  if v_missing>0 then
    raise exception 'Cannot remove TSE outlet links safely: % active outlets are missing consistent state/territory data. No assignment or outlet ownership links were cleared.',v_missing;
  end if;
end $$;

-- Keep historical assignment rows for audit, but deactivate every outlet-to-
-- person access link. User-to-user org_people mappings are not touched.
update public.promoter_outlet_assignments set active=false where active;
alter table public.promoter_outlet_workbook_assignments
  add column if not exists active boolean not null default true;
update public.promoter_outlet_workbook_assignments set active=false where active;
alter table public.org_person_outlet_workbook_assignments
  add column if not exists active boolean not null default true;
update public.org_person_outlet_workbook_assignments set active=false where active;

update public.outlets set tse_id=null,updated_at=now() where tse_id is not null;

-- Retain the existing bounded fallback list; the paginated search RPC below
-- is the source of the complete global outlet list.
create or replace function public.get_promoter_outlets()
returns table(id uuid,outlet_code text,name text,area text,city text,tse_id uuid,beat text)
language plpgsql stable security definer set search_path=public as $$
begin
  perform public._require_promoter();
  return query select o.id,o.outlet_code,o.name,o.area,o.city,o.tse_id,o.beat
    from public.outlets o where o.status='active' order by o.name,o.outlet_code limit 50;
end $$;

create table if not exists public.global_outlet_import_runs (
  id uuid primary key,
  expected_rows integer not null check (expected_rows >= 0),
  imported_rows integer not null default 0,
  status text not null default 'staging' check (status in ('staging','processing','published')),
  created_by uuid not null references auth.users(id),
  created_outlets integer not null default 0,
  matched_outlets integer not null default 0,
  created_at timestamptz not null default now(),
  published_at timestamptz
);

create table if not exists public.global_outlet_import_staging (
  import_id uuid not null references public.global_outlet_import_runs(id) on delete cascade,
  source_row_hash text not null,
  duplicate_occurrence integer not null check (duplicate_occurrence > 0),
  state_code text not null check (state_code in ('UP','MH')),
  outlet_name text not null,
  route text not null default '',
  area text not null default '',
  license_no text not null default '',
  address text not null default '',
  normalized_outlet_name text not null,
  normalized_license_no text not null,
  normalized_address text not null,
  primary key (import_id, source_row_hash, duplicate_occurrence)
);

alter table public.global_outlet_import_runs enable row level security;
alter table public.global_outlet_import_staging enable row level security;
revoke all on public.global_outlet_import_runs, public.global_outlet_import_staging from public, anon, authenticated;

create index if not exists outlet_search_master_operational_idx
  on public.outlet_search_master (operational_outlet_id) where is_active;
create index if not exists outlet_search_master_area_route_idx
  on public.outlet_search_master (state_code, normalized_outlet_name, is_active);

create or replace function public.begin_global_outlet_import(p_import_id uuid, p_expected_rows integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_run public.global_outlet_import_runs;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if p_import_id is null or p_expected_rows is null or p_expected_rows < 0 then raise exception 'INVALID_IMPORT'; end if;
  insert into public.global_outlet_import_runs(id,expected_rows,created_by)
    values(p_import_id,p_expected_rows,auth.uid()) on conflict(id) do nothing;
  select * into v_run from public.global_outlet_import_runs where id=p_import_id;
  if v_run.created_by<>auth.uid() or v_run.expected_rows<>p_expected_rows then raise exception 'IMPORT_RUN_CONFLICT'; end if;
  return jsonb_build_object('import_id',v_run.id,'status',v_run.status,'expected_rows',v_run.expected_rows);
end $$;

create or replace function public.import_global_outlet_batch(p_import_id uuid,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_run public.global_outlet_import_runs; r jsonb; v_state text; v_name text; v_route text; v_area text;
  v_license text; v_address text; v_occurrence integer; v_hash text; v_canonical text; v_count integer:=0;
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
    v_occurrence:=coalesce((r->>'duplicate_occurrence')::integer,0);
    if v_name is null or v_occurrence<1 then raise exception 'INVALID_OUTLET_ROW'; end if;
    v_canonical:=v_state||chr(31)||lower(v_name)||chr(31)||lower(v_route)||chr(31)||lower(v_area)||chr(31)||lower(v_license)||chr(31)||lower(v_address);
    v_hash:=encode(extensions.digest(convert_to(v_canonical,'UTF8'),'sha256'),'hex');
    insert into public.global_outlet_import_staging(import_id,source_row_hash,duplicate_occurrence,state_code,
      outlet_name,route,area,license_no,address,normalized_outlet_name,normalized_license_no,normalized_address)
    values(p_import_id,v_hash,v_occurrence,v_state,v_name,v_route,v_area,v_license,v_address,
      public.normalize_outlet_search_text(v_name),public.normalize_outlet_search_text(v_license),public.normalize_outlet_search_text(v_address))
    on conflict(import_id,source_row_hash,duplicate_occurrence) do update set
      outlet_name=excluded.outlet_name,route=excluded.route,area=excluded.area,license_no=excluded.license_no,
      address=excluded.address,normalized_outlet_name=excluded.normalized_outlet_name,
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

    insert into public.outlet_search_master(source_row_hash,duplicate_occurrence,state_code,outlet_name,license_no,address,
      normalized_outlet_name,normalized_license_no,normalized_address,is_active,imported_at,route,area,operational_outlet_id)
    values(r.source_row_hash,r.duplicate_occurrence,r.state_code,r.outlet_name,nullif(r.license_no,''),nullif(r.address,''),
      r.normalized_outlet_name,r.normalized_license_no,r.normalized_address,true,now(),nullif(r.route,''),nullif(r.area,''),v_outlet_id)
    on conflict(source_row_hash,duplicate_occurrence) do update set state_code=excluded.state_code,
      outlet_name=excluded.outlet_name,license_no=coalesce(excluded.license_no,public.outlet_search_master.license_no),
      address=coalesce(excluded.address,public.outlet_search_master.address),normalized_outlet_name=excluded.normalized_outlet_name,
      normalized_license_no=excluded.normalized_license_no,normalized_address=coalesce(nullif(excluded.normalized_address,''),public.outlet_search_master.normalized_address),
      route=excluded.route,area=excluded.area,operational_outlet_id=coalesce(public.outlet_search_master.operational_outlet_id,excluded.operational_outlet_id),
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

-- Search all active outlets and order results by exact, close, then broader
-- relevance. State, area, and licence are returned from the imported directory.
drop function if exists public.search_authorized_outlets(text,text,text,integer,integer);
create or replace function public.search_authorized_outlets(p_outlet_name text default null,p_address text default null,
  p_license_no text default null,p_limit integer default 30,p_offset integer default 0)
returns table(id uuid,outlet_code text,name text,area text,city text,tse_id uuid,beat text,
  directory_record_id uuid,license_no text,address text,state_code text,match_tier text,total_count bigint)
language plpgsql stable security definer set search_path=public,extensions as $$
declare v_name text:=nullif(public.normalize_outlet_search_text(p_outlet_name),'');
  v_license text:=nullif(public.normalize_outlet_search_text(p_license_no),'');
  v_limit integer:=greatest(1,least(coalesce(p_limit,30),50)); v_offset integer:=greatest(0,coalesce(p_offset,0));
begin
  perform public._require_promoter();
  if v_name is null and v_license is null then raise exception 'SEARCH_TERM_REQUIRED'; end if;
  if (v_name is not null and length(v_name)<2) or (v_license is not null and length(v_license)<2) then raise exception 'SEARCH_TERM_TOO_SHORT'; end if;
  return query with candidates as (
    select o.id,o.outlet_code,o.name,coalesce(d.area,o.area) area,o.city,o.tse_id,coalesce(d.route,o.beat) beat,
      d.id directory_record_id,d.license_no,d.address,d.state_code,
      case when v_name is null then 0 else greatest(
        case when public.normalize_outlet_search_text(o.name)=v_name or public.normalize_outlet_search_text(o.outlet_code)=v_name then 1.0 else 0.0 end,
        case when position(v_name in public.normalize_outlet_search_text(o.name))>0
          or position(v_name in public.normalize_outlet_search_text(o.outlet_code))>0
          or position(v_name in public.normalize_outlet_search_text(coalesce(d.area,o.area,'')))>0
          or position(v_name in public.normalize_outlet_search_text(coalesce(o.city,'')))>0
          or position(v_name in public.normalize_outlet_search_text(coalesce(d.route,o.beat,'')))>0 then 0.75 else 0.0 end,
        extensions.similarity(public.normalize_outlet_search_text(o.name),v_name),
        extensions.similarity(public.normalize_outlet_search_text(o.outlet_code),v_name),
        extensions.similarity(public.normalize_outlet_search_text(coalesce(d.area,o.area,'')),v_name),
        extensions.similarity(public.normalize_outlet_search_text(coalesce(o.city,'')),v_name),
        extensions.similarity(public.normalize_outlet_search_text(coalesce(d.route,o.beat,'')),v_name)) end name_score,
      case when v_license is null then 0 else greatest(
        case when d.normalized_license_no=v_license then 1.0 else 0.0 end,
        case when position(v_license in coalesce(d.normalized_license_no,''))>0 then 0.75 else 0.0 end,
        extensions.similarity(d.normalized_license_no,v_license)) end license_score
    from public.outlets o
    left join lateral (select m.id,m.license_no,m.address,m.normalized_license_no,m.area,m.route,m.state_code from public.outlet_search_master m
      where m.is_active and m.operational_outlet_id=o.id order by m.imported_at desc,m.id limit 1) d on true
    where o.status='active'
      and (v_name is null or public.normalize_outlet_search_text(o.name)=v_name
        or public.normalize_outlet_search_text(o.outlet_code)=v_name
        or position(v_name in public.normalize_outlet_search_text(o.name))>0
        or position(v_name in public.normalize_outlet_search_text(o.outlet_code))>0
        or position(v_name in public.normalize_outlet_search_text(coalesce(d.area,o.area,'')))>0
        or position(v_name in public.normalize_outlet_search_text(coalesce(o.city,'')))>0
        or position(v_name in public.normalize_outlet_search_text(coalesce(d.route,o.beat,'')))>0
        or extensions.similarity(public.normalize_outlet_search_text(o.name),v_name)>=0.12
        or extensions.similarity(public.normalize_outlet_search_text(o.outlet_code),v_name)>=0.12
        or extensions.similarity(public.normalize_outlet_search_text(coalesce(d.area,o.area,'')),v_name)>=0.12
        or extensions.similarity(public.normalize_outlet_search_text(coalesce(o.city,'')),v_name)>=0.12
        or extensions.similarity(public.normalize_outlet_search_text(coalesce(d.route,o.beat,'')),v_name)>=0.12)
      and (v_license is null or position(v_license in coalesce(d.normalized_license_no,''))>0
        or extensions.similarity(d.normalized_license_no,v_license)>=0.12)
  ), scored as (
    select c.*,case when v_name is not null and v_license is not null then least(c.name_score,c.license_score)
      when v_name is not null then c.name_score else c.license_score end relevance
    from candidates c
  )
  select c.id,c.outlet_code,c.name,c.area,c.city,c.tse_id,c.beat,c.directory_record_id,c.license_no,c.address,c.state_code,
    case when c.relevance>=0.999 then 'exact' when c.relevance>=0.5 then 'close' else 'broad' end,
    count(*) over()
  from scored c
  order by case when c.relevance>=0.999 then 0 when c.relevance>=0.5 then 1 else 2 end,
    c.relevance desc,c.name,c.area nulls last,c.outlet_code
  limit v_limit offset v_offset;
end $$;

create or replace function public.set_work_context_with_search(p_outlet_id uuid,p_device_ref text default null,p_directory_record_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb; v_license text; v_address text;
begin
  perform public._require_promoter();
  v_result:=public.set_work_context(p_outlet_id,p_device_ref);
  if p_directory_record_id is not null then
    select d.license_no,d.address into v_license,v_address from public.outlet_search_master d
      where d.id=p_directory_record_id and d.is_active and d.operational_outlet_id=p_outlet_id;
    if not found then raise exception 'OUTLET_SEARCH_MATCH_INVALID'; end if;
  end if;
  update public.promoter_sessions set outlet_search_master_id=p_directory_record_id,outlet_license_no=v_license,
    outlet_address=v_address,updated_at=now() where promoter_id=auth.uid() and work_date=public.ist_today() and outlet_id=p_outlet_id;
  if not found then raise exception 'WORK_SESSION_NOT_FOUND'; end if;
  if p_directory_record_id is not null then perform public.write_audit('OUTLET_IDENTIFICATION_SELECTED','outlets',p_outlet_id::text,
    jsonb_build_object('directory_record_id',p_directory_record_id,'license_no',v_license,'address',v_address)); end if;
  return v_result;
end $$;

revoke all on function public.begin_global_outlet_import(uuid,integer),public.import_global_outlet_batch(uuid,jsonb),
  public.finalize_global_outlet_import(uuid),public.search_authorized_outlets(text,text,text,integer,integer),
  public.set_work_context_with_search(uuid,text,uuid) from public,anon;
grant execute on function public.begin_global_outlet_import(uuid,integer),public.import_global_outlet_batch(uuid,jsonb),
  public.finalize_global_outlet_import(uuid),public.search_authorized_outlets(text,text,text,integer,integer),
  public.set_work_context_with_search(uuid,text,uuid) to authenticated;
