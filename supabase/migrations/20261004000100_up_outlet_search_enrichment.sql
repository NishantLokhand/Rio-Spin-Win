-- UP outlet identification directory. These rows enrich authorized operational
-- outlets; they never create outlets or grant access.

create or replace function public.normalize_outlet_search_text(p_value text)
returns text
language sql immutable parallel safe set search_path = pg_catalog as $$
  select regexp_replace(lower(normalize(coalesce(p_value, ''), NFKC)), '[^[:alnum:]]+', '', 'g')
$$;

create table if not exists public.outlet_search_import_runs (
  id uuid primary key,
  expected_rows integer not null check (expected_rows >= 0),
  status text not null default 'staging' check (status in ('staging', 'published')),
  imported_rows integer,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  published_at timestamptz
);

create table if not exists public.outlet_search_import_staging (
  import_id uuid not null references public.outlet_search_import_runs(id) on delete cascade,
  source_row_hash text not null,
  duplicate_occurrence integer not null check (duplicate_occurrence > 0),
  outlet_name text not null,
  license_no text,
  address text,
  normalized_outlet_name text not null,
  normalized_license_no text not null,
  normalized_address text not null,
  primary key (import_id, source_row_hash, duplicate_occurrence)
);

create table if not exists public.outlet_search_master (
  id uuid primary key default gen_random_uuid(),
  source_row_hash text not null,
  duplicate_occurrence integer not null check (duplicate_occurrence > 0),
  state_code text not null default 'UP' check (state_code = 'UP'),
  outlet_name text not null,
  license_no text,
  address text,
  normalized_outlet_name text not null,
  normalized_license_no text not null,
  normalized_address text not null,
  is_active boolean not null default true,
  imported_at timestamptz not null default now(),
  unique (source_row_hash, duplicate_occurrence)
);

alter table public.promoter_sessions
  add column if not exists outlet_search_master_id uuid references public.outlet_search_master(id) on delete set null,
  add column if not exists outlet_license_no text,
  add column if not exists outlet_address text;

alter table public.sales
  add column if not exists outlet_search_master_id uuid references public.outlet_search_master(id) on delete set null,
  add column if not exists outlet_license_no text,
  add column if not exists outlet_address text;

alter table public.outlet_search_master enable row level security;
alter table public.outlet_search_import_runs enable row level security;
alter table public.outlet_search_import_staging enable row level security;
revoke all on public.outlet_search_master, public.outlet_search_import_runs, public.outlet_search_import_staging from public, anon, authenticated;

create index if not exists outlet_search_master_active_name_idx
  on public.outlet_search_master (state_code, normalized_outlet_name) where is_active;
create index if not exists outlets_normalized_name_idx
  on public.outlets (public.normalize_outlet_search_text(name)) where status = 'active';

-- Check availability before enabling pg_trgm. Supabase installations that do
-- not offer this extension fail this migration before it can be applied.
do $$
declare v_opclass_schema text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_trgm') then
    if not exists (select 1 from pg_available_extensions where name = 'pg_trgm') then
      raise exception 'pg_trgm is unavailable on this database; outlet search migration was not applied';
    end if;
    create extension pg_trgm with schema extensions;
  end if;

  select ns.nspname into v_opclass_schema
    from pg_opclass oc join pg_am am on am.oid = oc.opcmethod
    join pg_namespace ns on ns.oid = oc.opcnamespace
   where oc.opcname = 'gin_trgm_ops' and am.amname = 'gin'
   order by (ns.nspname = 'extensions') desc limit 1;
  if v_opclass_schema is null then raise exception 'pg_trgm GIN operator class is unavailable'; end if;

  execute format('create index if not exists outlet_search_master_name_trgm_idx on public.outlet_search_master using gin (normalized_outlet_name %I.gin_trgm_ops) where is_active', v_opclass_schema);
  execute format('create index if not exists outlet_search_master_license_trgm_idx on public.outlet_search_master using gin (normalized_license_no %I.gin_trgm_ops) where is_active', v_opclass_schema);
  execute format('create index if not exists outlet_search_master_address_trgm_idx on public.outlet_search_master using gin (normalized_address %I.gin_trgm_ops) where is_active', v_opclass_schema);
end $$;

create or replace function public.begin_up_outlet_search_import(p_import_id uuid, p_expected_rows integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_run public.outlet_search_import_runs;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if p_import_id is null or p_expected_rows is null or p_expected_rows < 0 then raise exception 'INVALID_IMPORT'; end if;

  delete from public.outlet_search_import_runs
   where status = 'staging' and created_at < now() - interval '2 days';

  insert into public.outlet_search_import_runs(id, expected_rows, created_by)
  values (p_import_id, p_expected_rows, auth.uid())
  on conflict (id) do nothing;
  select * into v_run from public.outlet_search_import_runs where id = p_import_id;
  if v_run.created_by <> auth.uid() or v_run.expected_rows <> p_expected_rows then raise exception 'IMPORT_RUN_CONFLICT'; end if;
  return jsonb_build_object('import_id', v_run.id, 'status', v_run.status, 'expected_rows', v_run.expected_rows);
end $$;

create or replace function public.import_up_outlet_search_batch(p_import_id uuid, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_run public.outlet_search_import_runs; r jsonb; v_name text; v_license text; v_address text;
  v_occurrence integer; v_canonical text; v_hash text; v_count integer := 0;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  if p_rows is null or jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'INVALID_IMPORT_BATCH'; end if;
  select * into v_run from public.outlet_search_import_runs where id = p_import_id for update;
  if v_run.id is null or v_run.created_by <> auth.uid() then raise exception 'IMPORT_RUN_NOT_FOUND'; end if;
  if v_run.status <> 'staging' then return jsonb_build_object('accepted', 0, 'status', v_run.status); end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_name := nullif(btrim(regexp_replace(normalize(coalesce(r->>'outlet_name', ''), NFKC), '\s+', ' ', 'g')), '');
    v_license := nullif(btrim(regexp_replace(normalize(coalesce(r->>'license_no', ''), NFKC), '\s+', ' ', 'g')), '');
    v_address := nullif(btrim(regexp_replace(normalize(coalesce(r->>'address', ''), NFKC), '\s+', ' ', 'g')), '');
    v_occurrence := coalesce((r->>'duplicate_occurrence')::integer, 0);
    if v_name is null or v_occurrence < 1 then raise exception 'INVALID_OUTLET_SEARCH_ROW'; end if;

    v_canonical := lower(regexp_replace(normalize(v_name, NFKC), '\s+', ' ', 'g')) || chr(31)
      || lower(regexp_replace(normalize(coalesce(v_license, ''), NFKC), '\s+', ' ', 'g')) || chr(31)
      || lower(regexp_replace(normalize(coalesce(v_address, ''), NFKC), '\s+', ' ', 'g'));
    v_hash := encode(extensions.digest(convert_to(v_canonical, 'UTF8'), 'sha256'), 'hex');

    insert into public.outlet_search_import_staging(
      import_id, source_row_hash, duplicate_occurrence, outlet_name, license_no, address,
      normalized_outlet_name, normalized_license_no, normalized_address)
    values (p_import_id, v_hash, v_occurrence, v_name, v_license, v_address,
      public.normalize_outlet_search_text(v_name), public.normalize_outlet_search_text(v_license), public.normalize_outlet_search_text(v_address))
    on conflict (import_id, source_row_hash, duplicate_occurrence) do update set
      outlet_name = excluded.outlet_name, license_no = excluded.license_no, address = excluded.address,
      normalized_outlet_name = excluded.normalized_outlet_name, normalized_license_no = excluded.normalized_license_no,
      normalized_address = excluded.normalized_address;
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('accepted', v_count, 'status', 'staging');
end $$;

create or replace function public.finalize_up_outlet_search_import(p_import_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_run public.outlet_search_import_runs; v_count integer;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  select * into v_run from public.outlet_search_import_runs where id = p_import_id for update;
  if v_run.id is null or v_run.created_by <> auth.uid() then raise exception 'IMPORT_RUN_NOT_FOUND'; end if;
  if v_run.status = 'published' then return jsonb_build_object('status', 'published', 'rows', v_run.imported_rows); end if;

  select count(*) into v_count from public.outlet_search_import_staging where import_id = p_import_id;
  if v_count <> v_run.expected_rows then
    raise exception 'OUTLET_SEARCH_IMPORT_INCOMPLETE' using detail = format('Expected %s rows, staged %s.', v_run.expected_rows, v_count);
  end if;

  update public.outlet_search_master set is_active = false where state_code = 'UP';
  insert into public.outlet_search_master(
    source_row_hash, duplicate_occurrence, state_code, outlet_name, license_no, address,
    normalized_outlet_name, normalized_license_no, normalized_address, is_active, imported_at)
  select source_row_hash, duplicate_occurrence, 'UP', outlet_name, license_no, address,
    normalized_outlet_name, normalized_license_no, normalized_address, true, now()
    from public.outlet_search_import_staging where import_id = p_import_id
  on conflict (source_row_hash, duplicate_occurrence) do update set
    state_code = excluded.state_code, outlet_name = excluded.outlet_name, license_no = excluded.license_no,
    address = excluded.address, normalized_outlet_name = excluded.normalized_outlet_name,
    normalized_license_no = excluded.normalized_license_no, normalized_address = excluded.normalized_address,
    is_active = true, imported_at = excluded.imported_at;

  update public.outlet_search_import_runs set status = 'published', imported_rows = v_count, published_at = now()
   where id = p_import_id;
  delete from public.outlet_search_import_staging where import_id = p_import_id;
  return jsonb_build_object('status', 'published', 'rows', v_count);
end $$;

create or replace function public.search_authorized_outlets(
  p_outlet_name text default null, p_address text default null, p_license_no text default null,
  p_limit integer default 30, p_offset integer default 0)
returns table (
  id uuid, outlet_code text, name text, area text, city text, tse_id uuid, beat text,
  directory_record_id uuid, license_no text, address text, total_count bigint)
language plpgsql stable security definer set search_path = public as $$
declare v_name text := public.normalize_outlet_search_text(p_outlet_name);
  v_address text := public.normalize_outlet_search_text(p_address);
  v_license text := public.normalize_outlet_search_text(p_license_no);
  v_limit integer := greatest(1, least(coalesce(p_limit, 30), 50));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if (coalesce(v_name, '') = '' and coalesce(v_address, '') = '' and coalesce(v_license, '') = '') then
    v_name := null; v_address := null; v_license := null;
  end if;
  if (v_name is not null and length(v_name) < 2) or (v_address is not null and length(v_address) < 2)
     or (v_license is not null and length(v_license) < 2) then
    raise exception 'SEARCH_TERM_TOO_SHORT';
  end if;

  return query
  with authorized as (
    select a.id, a.outlet_code, a.name, a.area, a.city, a.tse_id, a.beat,
      d.id as directory_record_id, d.license_no, d.address
    from public.get_promoter_outlets() a
    join public.outlets o on o.id = a.id
    left join public.tses t on t.id = o.tse_id
    left join public.territories tr on tr.id = t.territory_id
    left join public.states st on st.id = tr.state_id
    left join lateral (
      select m.id, m.license_no, m.address, m.normalized_license_no, m.normalized_address
        from public.outlet_search_master m
       where m.is_active and upper(st.code) = 'UP' and m.state_code = 'UP'
         and m.normalized_outlet_name = public.normalize_outlet_search_text(o.name)
       order by m.license_no nulls last, m.address nulls last, m.id
    ) d on true
    where (v_name is null or public.normalize_outlet_search_text(a.name) like '%' || v_name || '%'
       or public.normalize_outlet_search_text(a.outlet_code) like '%' || v_name || '%'
       or public.normalize_outlet_search_text(a.area) like '%' || v_name || '%'
       or public.normalize_outlet_search_text(a.city) like '%' || v_name || '%')
      and (v_address is null or d.normalized_address like '%' || v_address || '%')
      and (v_license is null or d.normalized_license_no like '%' || v_license || '%')
  )
  select a.id, a.outlet_code, a.name, a.area, a.city, a.tse_id, a.beat,
    a.directory_record_id, a.license_no, a.address, count(*) over ()
  from authorized a
  order by a.name, a.area nulls last, a.outlet_code, a.license_no nulls last, a.address nulls last
  limit v_limit offset v_offset;
end $$;

create or replace function public.set_work_context_with_search(
  p_outlet_id uuid, p_device_ref text default null, p_directory_record_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb; v_license text; v_address text;
begin
  perform public._require_promoter();
  v_result := public.set_work_context(p_outlet_id, p_device_ref);
  if p_directory_record_id is not null then
    select d.license_no, d.address into v_license, v_address
      from public.outlet_search_master d
      join public.outlets o on o.id = p_outlet_id
      join public.tses t on t.id = o.tse_id
      join public.territories tr on tr.id = t.territory_id
      join public.states st on st.id = tr.state_id
     where d.id = p_directory_record_id and d.is_active and d.state_code = 'UP' and upper(st.code) = 'UP'
       and d.normalized_outlet_name = public.normalize_outlet_search_text(o.name);
    if not found then raise exception 'OUTLET_SEARCH_MATCH_INVALID'; end if;
  end if;

  update public.promoter_sessions set outlet_search_master_id = p_directory_record_id,
    outlet_license_no = v_license, outlet_address = v_address, updated_at = now()
   where promoter_id = auth.uid() and work_date = public.ist_today() and outlet_id = p_outlet_id;
  if not found then raise exception 'WORK_SESSION_NOT_FOUND'; end if;

  if p_directory_record_id is not null then
    perform public.write_audit('OUTLET_IDENTIFICATION_SELECTED', 'outlets', p_outlet_id::text,
      jsonb_build_object('directory_record_id', p_directory_record_id, 'license_no', v_license, 'address', v_address));
  end if;
  return v_result;
end $$;

create or replace function public._snapshot_sale_outlet_search()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select ps.outlet_search_master_id, ps.outlet_license_no, ps.outlet_address
    into new.outlet_search_master_id, new.outlet_license_no, new.outlet_address
    from public.promoter_sessions ps
   where ps.promoter_id = new.promoter_id and ps.work_date = new.biz_date and ps.outlet_id = new.outlet_id;
  return new;
end $$;
drop trigger if exists sales_outlet_search_snapshot on public.sales;
create trigger sales_outlet_search_snapshot before insert on public.sales
for each row execute function public._snapshot_sale_outlet_search();

create or replace function public._audit_sale_outlet_search()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.outlet_search_master_id is not null then
    perform public.write_audit('SALE_OUTLET_IDENTIFICATION_SNAPSHOT', 'sales', new.id::text,
      jsonb_build_object('directory_record_id', new.outlet_search_master_id,
        'license_no', new.outlet_license_no, 'address', new.outlet_address));
  end if;
  return new;
end $$;
drop trigger if exists sales_outlet_search_audit on public.sales;
create trigger sales_outlet_search_audit after insert on public.sales
for each row execute function public._audit_sale_outlet_search();

-- Keep the view's existing columns in place and append nullable historical fields.
create or replace view public.v_transactions with (security_invoker = true) as
select
  s.id as transaction_id, sp.spin_code as spin_id, c.code as campaign_code, s.campaign_id,
  s.biz_date as date, to_char(sp.created_at at time zone 'Asia/Kolkata', 'HH24:MI:SS') as time,
  s.state_name as state, s.territory_name as territory, s.tse_id, s.tse_code, s.tse_name,
  s.outlet_id, s.outlet_code, s.outlet_name, s.outlet_area as area, s.outlet_city as city, s.distributor,
  s.promoter_id, s.promoter_code, s.promoter_name, s.promoter_type,
  coalesce(items.sku_codes, s.sku_code) as sku_code,
  coalesce(items.product_names, s.product_name) as sku,
  s.quantity, sp.prize_id, sp.prize_name, sp.prize_cost, sp.substituted,
  sp.redemption_status, sp.inventory_status, sp.handed_over_at, s.status as sale_status,
  coalesce(sp.device_ref, s.device_ref) as device_ref, s.state_id, s.territory_id, s.product_id,
  sp.config_version, sp.created_at as spun_at, coalesce(items.product_ids, array[s.product_id]) as product_ids,
  s.outlet_search_master_id, s.outlet_license_no, s.outlet_address
from public.sales s join public.campaigns c on c.id = s.campaign_id
left join public.spins sp on sp.sale_id = s.id
left join lateral (
  select string_agg(si.sku_code || ' × ' || si.quantity, ', ' order by si.sku_code) as sku_codes,
         string_agg(si.product_name || ' × ' || si.quantity, ', ' order by si.sku_code) as product_names,
         array_agg(si.product_id order by si.product_id) as product_ids
    from public.sale_items si where si.sale_id = s.id
) items on true;
grant select on public.v_transactions to authenticated;

revoke all on function public.normalize_outlet_search_text(text),
  public.begin_up_outlet_search_import(uuid, integer), public.import_up_outlet_search_batch(uuid, jsonb),
  public.finalize_up_outlet_search_import(uuid), public.search_authorized_outlets(text, text, text, integer, integer),
  public.set_work_context_with_search(uuid, text, uuid), public._snapshot_sale_outlet_search(),
  public._audit_sale_outlet_search() from public, anon;
revoke all on function public.begin_up_outlet_search_import(uuid, integer),
  public.import_up_outlet_search_batch(uuid, jsonb), public.finalize_up_outlet_search_import(uuid),
  public.search_authorized_outlets(text, text, text, integer, integer),
  public.set_work_context_with_search(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.begin_up_outlet_search_import(uuid, integer),
  public.import_up_outlet_search_batch(uuid, jsonb), public.finalize_up_outlet_search_import(uuid),
  public.search_authorized_outlets(text, text, text, integer, integer),
  public.set_work_context_with_search(uuid, text, uuid) to authenticated;

notify pgrst, 'reload schema';
