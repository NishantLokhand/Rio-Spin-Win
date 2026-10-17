import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { parseGlobalOutletWorkbook } from '../web/src/lib/globalOutletWorkbook.js';
const header = ['State','Outlet NAME','ROUTE','AREA','LICNO','MARKET'];
const source = ['Maharashtra','Test Wines','Route 1','Area 1','L1','ROM_AMRAVATI'];
assert.equal(parseGlobalOutletWorkbook([header,source])[0].city,'ROM_AMRAVATI');
assert.equal(parseGlobalOutletWorkbook([header.slice(0,5),source.slice(0,5)])[0].city,'');
assert.equal(parseGlobalOutletWorkbook([[...header.slice(0,5),'City'],source])[0].city,'ROM_AMRAVATI');
assert.equal(parseGlobalOutletWorkbook([header,[...source.slice(0,4),0,source[5]]])[0].license_no,'0');
assert.throws(() => parseGlobalOutletWorkbook([header,source,[...source.slice(0,5),'OTHER']]), /conflicting/);
const { PGlite } = await import('../.cache/onboarding-tests/node_modules/@electric-sql/pglite/dist/index.js');
const db = new PGlite();
const base = await readFile(new URL('../supabase/migrations/20261008000100_global_outlet_directory.sql',import.meta.url),'utf8');
await db.exec(`create role anon; create role authenticated; create schema auth; create schema extensions;
create function auth.uid() returns uuid language sql as $$ select current_setting('test.actor')::uuid $$;
create function is_admin() returns boolean language sql as $$ select current_setting('test.admin')='yes' $$;
create function normalize_outlet_search_text(text) returns text language sql immutable as $$ select lower(regexp_replace($1,'[^a-zA-Z0-9]','','g')) $$;
-- Deterministic digest stand-in: tests identity stability, not SHA implementation.
create function extensions.digest(bytea,text) returns bytea language sql as $$ select decode(md5($1),'hex') $$;
create table auth.users(id uuid primary key);
create table app_users(id uuid,role text);
create function _require_staff() returns app_users language plpgsql as $$ declare u app_users; begin
select * into u from app_users where id=auth.uid(); if u.role not in ('admin','supervisor') or u.id is null then raise exception 'STAFF_ONLY'; end if; return u; end $$;
create function write_audit(text,text,text,jsonb) returns void language sql as $$ select $$;
create table states(id uuid primary key default gen_random_uuid(),code text,name text);
create table territories(id uuid primary key default gen_random_uuid(),state_id uuid,code text,name text);
create table tses(id uuid,territory_id uuid);
create table promoters(user_id uuid,supervisor_id uuid);
create table outlets(id uuid primary key default gen_random_uuid(),tse_id uuid,outlet_code text,name text,area text,beat text,city text,status text,source text,state_id uuid,territory_id uuid,updated_at timestamptz);
create table sales(id uuid primary key default gen_random_uuid(),outlet_id uuid,outlet_city text,outlet_area text,state_id uuid,promoter_id uuid,quantity int);
create table outlet_search_master(source_row_hash text,duplicate_occurrence int,state_code text,outlet_name text,license_no text,address text,normalized_outlet_name text,normalized_license_no text,normalized_address text,is_active boolean,imported_at timestamptz,route text,area text,operational_outlet_id uuid,unique(source_row_hash,duplicate_occurrence));
${base.slice(base.indexOf('create table if not exists public.global_outlet_import_runs'),base.indexOf('alter table public.global_outlet_import_runs enable'))}
${base.slice(base.indexOf('create or replace function public.begin_global_outlet_import'),base.indexOf('-- Search all active outlets'))}`);
const actor=randomUUID(); await db.query('insert into auth.users values ($1)',[actor]);
await db.query("insert into app_users values ($1,'admin')",[actor]);
await db.exec(`set test.actor='${actor}'; set test.admin='yes';`);
async function upload(rows) {
  const id=randomUUID();
  await db.query('select begin_global_outlet_import($1,$2)',[id,rows.length]);
  await db.query('select import_global_outlet_batch($1,$2)',[id,rows]);
  return (await db.query('select finalize_global_outlet_import($1) r',[id])).rows[0].r;
}
// Import old format first, then enrich the exact same outlet with MARKET.
await upload(parseGlobalOutletWorkbook([header.slice(0,5),source.slice(0,5)]));
const outlet=(await db.query('select * from outlets')).rows[0];
await db.query("insert into sales(outlet_id,outlet_city,outlet_area,state_id,promoter_id,quantity) values ($1,null,'Area 1',$2,$3,2),($1,'Recorded City','Area 1',$2,$3,3)",[outlet.id,outlet.state_id,actor]);
await db.exec(await readFile(new URL('../supabase/migrations/20261017000400_import_outlet_market_city.sql',import.meta.url),'utf8'));
await upload(parseGlobalOutletWorkbook([header,source]));
assert.equal((await db.query('select count(*) from outlets')).rows[0].count,1);
assert.equal((await db.query('select city from outlets where id=$1',[outlet.id])).rows[0].city,'ROM_AMRAVATI');
assert.deepEqual((await db.query('select outlet_city from sales order by quantity')).rows.map(r=>r.outlet_city),['ROM_AMRAVATI','Recorded City']);
assert.equal((await db.query('select sum(quantity) n from sales')).rows[0].n,5);
await upload(parseGlobalOutletWorkbook([header,source]));
await upload(parseGlobalOutletWorkbook([header.slice(0,5),source.slice(0,5)]));
assert.equal((await db.query('select count(*) from outlets')).rows[0].count,1);
assert.equal((await db.query('select city from outlets')).rows[0].city,'ROM_AMRAVATI');
assert.ok((await db.query("select get_report_cities(null,'Area 1') c")).rows[0].c.includes('ROM_AMRAVATI'));
assert.deepEqual((await db.query("select get_report_cities(null,'Other area') c")).rows[0].c,[]);
const supervisor=randomUUID();
await db.query("insert into app_users values ($1,'supervisor')",[supervisor]);
await db.exec(`set test.actor='${supervisor}'`);
assert.deepEqual((await db.query('select get_report_cities(null,null) c')).rows[0].c,[]);
await db.query('insert into promoters values ($1,$2)',[actor,supervisor]);
assert.ok((await db.query('select get_report_cities(null,null) c')).rows[0].c.includes('ROM_AMRAVATI'));
await db.exec(`set test.actor='${actor}'`);
await db.exec("set test.admin='no'");
await assert.rejects(()=>upload(parseGlobalOutletWorkbook([header,source])),/ADMIN_ONLY/);
await db.close(); console.log('PASS: MARKET parsing, conflict rejection, stable outlet IDs, repeat imports, legacy files, historical city repair, preserved totals and city filters.');
