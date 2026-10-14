// Run with PGLITE_MODULE pointing to an installed @electric-sql/pglite module.
// Uses the real table definitions and onboarding migration in isolated Postgres.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
const { PGlite } = await import(process.env.PGLITE_MODULE || '../.cache/onboarding-tests/node_modules/@electric-sql/pglite/dist/index.js');
const db = new PGlite();
const read = (name) => readFile(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8');
const schema = await read('20260928000100_schema.sql');
const org = await read('20260930000500_master_inventory_assignments.sql');
await db.exec(`create role anon; create role authenticated; create role service_role;
create schema auth; create table auth.users(id uuid primary key);
create type public.user_role as enum ('promoter','supervisor','admin');
create type public.promoter_type as enum ('permanent','temporary','spot_selling','agency');
create table public.states(id uuid primary key);
${schema.slice(schema.indexOf('create table public.app_users'), schema.indexOf('-- ---------------------------------------------------------------------\n-- PRODUCTS'))}
${org.slice(org.indexOf('create table public.org_people'), org.indexOf('create index org_people_role_geo_idx'))}
create table public.test_audit(actor uuid,action text,entity text,entity_id text,details jsonb);
create function public.write_audit_as(uuid,text,text,text,jsonb) returns void language sql as
'insert into public.test_audit values ($1,$2,$3,$4,$5)';`);
await db.exec(await read('20261014000100_create_linked_field_user.sql'));
const actor = randomUUID();
await db.query('insert into auth.users values ($1)', [actor]);
await db.query("insert into public.app_users(id,role,login_id,full_name) values ($1,'admin','admin','Admin')", [actor]);
async function create({ designation = 'PROMOTER', person_id, mobile = randomUUID(), actorId = actor, promoter = {}, name = 'Test Employee' } = {}) {
  const id = randomUUID();
  await db.query('insert into auth.users values ($1)', [id]);
  const run = () => db.query('select public.create_linked_field_user($1,$2,$3,$4,$5,$6,$7) as result',
    [actorId, id, mobile, name, mobile, promoter, { designation, person_id, state: 'Maharashtra', market: 'Mumbai', beat: 'Mulund' }]);
  return { id, run };
}
for (const designation of ['PROMOTER', 'TSE', 'MER']) {
  const { id, run } = await create({ designation }); await run();
  const { rows } = await db.query('select designation,auth_user_id,active,market_raw from public.org_people where auth_user_id=$1', [id]);
  assert.equal(rows.length, 1); assert.equal(rows[0].designation, designation);
  assert.equal(rows[0].active, true); assert.equal(rows[0].market_raw, 'Mumbai');
  assert.equal((await db.query('select * from public.promoters where user_id=$1', [id])).rows.length, 1);
}
const person = randomUUID(); const mobile = '9082483513';
await db.query("insert into public.org_people(id,designation,employee_name,mobile,source_key,source_system,market_raw) values ($1,'TSE','Existing Employee',$2,'imported','workbook','Original market')", [person, mobile]);
const duplicate = await create({ designation: 'TSE', mobile });
await assert.rejects(duplicate.run, /already uses this mobile/);
assert.equal((await db.query('select * from public.app_users where id=$1', [duplicate.id])).rows.length, 0);
const existing = await create({ designation: 'TSE', mobile, person_id: person }); await existing.run();
assert.equal((await db.query('select market_raw from public.org_people where id=$1', [person])).rows[0].market_raw, 'Original market');
const relink = await create({ designation: 'TSE', person_id: person });
await assert.rejects(relink.run, /already has a linked login/);
for (const options of [{ designation: 'ASM' }, { actorId: randomUUID() }, { designation: 'MER', person_id: person }, { promoter: { promoter_type: 'invalid' } }]) {
  const request = await create(options); await assert.rejects(request.run);
  assert.equal((await db.query('select * from public.app_users where id=$1', [request.id])).rows.length, 0);
  assert.equal((await db.query('select * from public.org_people where auth_user_id=$1', [request.id])).rows.length, 0);
}
await db.exec('set role authenticated');
await assert.rejects(() => db.query('select public.create_linked_field_user($1,$2,$3,$4,$5,$6,$7)', [actor, randomUUID(), 'forbidden', 'Forbidden', null, {}, {}]), /permission denied/);
await db.exec('reset role');
await db.close();
console.log('PASS: new PROMOTER/TSE/MER profiles, imported record linking, duplicate/relink protection, authorization and atomic failure rollback');
