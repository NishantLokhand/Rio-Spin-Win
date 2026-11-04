import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '../.cache/onboarding-tests/node_modules/@electric-sql/pglite/dist/index.js';
const db = new PGlite();
await db.exec(`
  create table territories(id uuid, state_id int, code text, name text);
  insert into territories values
    ('00000000-0000-0000-0000-000000000001',1,'GLOBAL-OUTLETS-MH','Global outlet directory'),
    ('00000000-0000-0000-0000-000000000002',1,'MUM','MUMBAI'),
    ('00000000-0000-0000-0000-000000000003',1,'WEST','Mumbai West'),
    ('00000000-0000-0000-0000-000000000004',2,'MUM','MUMBAI');
  create table sales(id int, state_id int, territory_id uuid, territory_name text, outlet_city text, spins int);
  insert into sales values
    (1,1,'00000000-0000-0000-0000-000000000002','MUMBAI','MUMBAI',25),
    (2,1,'00000000-0000-0000-0000-000000000001','Global outlet directory','MUMBAI MKT',253),
    (3,1,'00000000-0000-0000-0000-000000000001','Global outlet directory','Mumbai',19),
    (4,1,'00000000-0000-0000-0000-000000000003','Mumbai West','Mumbai',8),
    (5,1,'00000000-0000-0000-0000-000000000001','Global outlet directory','Unknown',7);
  create view report_sales_resolved with (security_invoker=true) as select * from sales;
`);
await db.exec(await readFile(new URL('../supabase/migrations/20261104000100_resolve_directory_report_territories.sql', import.meta.url), 'utf8'));
const rows = (await db.query('select * from report_sales_resolved order by id')).rows;
assert.equal(rows.filter(r => r.territory_name === 'MUMBAI').reduce((n,r) => n+r.spins,0),297);
assert.equal(rows[3].territory_name,'Mumbai West');
assert.equal(rows[4].territory_name,'Global outlet directory');
assert.equal(rows.length,5);
assert.equal((await db.query('select territory_name from sales where id=2')).rows[0].territory_name,'Global outlet directory');
// Ambiguous names must not duplicate transactions or choose an arbitrary territory.
await db.exec(`insert into territories values ('00000000-0000-0000-0000-000000000005',1,'DUP','Mumbai')`);
assert.equal((await db.query('select territory_name from report_sales_resolved where id=2')).rows[0].territory_name,'Global outlet directory');
assert.equal((await db.query('select count(*)::int as n from report_sales_resolved')).rows[0].n,5);
// Replace the earlier view mapping with the approved additive filter design.
await db.exec(`
  create table states(id int,code text);
  insert into states values (1,'MH'),(2,'UP');
  create table outlet_identity_links(legacy_outlet_id int,directory_record_id int,verified_licence text);
  create table outlet_search_master(id int,operational_outlet_id int,outlet_name text,city text,area text,state_code text,normalized_license_no text);
  create table outlets(id int,outlet_code text);
  create function normalize_outlet_search_text(text) returns text language sql immutable as $$select lower($1)$$;
  alter table sales add column outlet_id int, add column outlet_search_master_id int, add column outlet_license_no text;
  create function _sales_where() returns text language sql immutable as $f$
    select $$($1->>'territory_id' is null or s.territory_id = ($1->>'territory_id')::uuid)
      and ($1->>'date_from' is null or s.id >= ($1->>'date_from')::int)$$
  $f$;
  insert into territories values
    ('00000000-0000-0000-0000-000000000006',1,'THANE','THANE'),
    ('00000000-0000-0000-0000-000000000007',2,'GLOBAL-OUTLETS-UP','Global outlet directory');
  insert into sales(id,state_id,territory_id,territory_name,outlet_city,spins) values
    (6,1,'00000000-0000-0000-0000-000000000001','Global outlet directory','THANE MKT',45),
    (7,2,'00000000-0000-0000-0000-000000000007','Global outlet directory','Mumbai',90);
`);
const baseline = (await db.query('select * from sales order by id')).rows;
const correction = await readFile(new URL('../supabase/migrations/20261104000200_preserve_directory_expand_region_filters.sql', import.meta.url), 'utf8');
await db.exec(correction);
assert.deepEqual((await db.query('select * from report_sales_resolved order by id')).rows,baseline);
const predicate = (await db.query('select _sales_where() as p')).rows[0].p;
await db.exec(`create function filtered_spins(jsonb) returns bigint language sql as $f$
  select coalesce(sum(s.spins),0)::bigint from report_sales_resolved s where ${predicate}
$f$;`);
const sum = async (id, extra={}) => Number((await db.query('select filtered_spins($1) as n', [{territory_id:id,...extra}])).rows[0].n);
assert.equal(await sum('00000000-0000-0000-0000-000000000002'),297);
assert.equal(await sum('00000000-0000-0000-0000-000000000001'),324);
assert.equal(await sum('00000000-0000-0000-0000-000000000006'),45);
assert.equal(await sum('00000000-0000-0000-0000-000000000003'),8);
assert.equal(await sum('00000000-0000-0000-0000-000000000004'),90);
assert.equal(await sum('00000000-0000-0000-0000-000000000002',{date_from:3}),19);
assert.equal(await sum(null),447);
await db.exec(correction);
assert.equal((await db.query('select _sales_where() as p')).rows[0].p,predicate);
await db.close();
console.log('PASS: Mumbai 297; directory 324 unchanged; Thane and second state; explicit territories; remaining filters; all-region totals; idempotence; unchanged view/sales');
