// Local Docker only. Creates a new DB from schema (never copies source data).
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import master from '../test/fixtures/userMasterMarkets.mjs';

const container = 'supabase_db_rio-spin-win-v7-sandbox';
const database = `rio_market_validation_${Date.now()}`;
let lastStderr = '';
const log = [`Local Docker PostgreSQL validation: ${new Date().toISOString()}`, `Container: ${container}`, `Isolated database: ${database}`, 'Schema only; synthetic fixtures; no production access.'];
function docker(args, input) {
  const result = spawnSync('docker', ['exec', '-i', container, ...args], { input, encoding: 'utf8', maxBuffer: 30 * 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`${args[0]} failed: ${result.error || ''}\n${result.stdout}\n${result.stderr}`);
  lastStderr = result.stderr || '';
  return result.stdout;
}
function sql(source, label) {
  const result = docker(['psql', '-X', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], source);
  log.push(`${label}: PASS\n${result.trim()}\n${lastStderr.trim()}`);
  console.log(`${label}: PASS`);
}
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
try {
  docker(['createdb', '-U', 'postgres', database]);
  sql('create schema extensions; create extension pgcrypto with schema extensions; create extension pg_trgm with schema extensions;', 'Bootstrap local database');
  const dump = docker(['pg_dump', '-U', 'postgres', '-d', 'postgres', '--schema-only', '--no-owner', '--no-privileges', '--schema=public', '--schema=auth']);
  sql(dump.replace('CREATE SCHEMA public;', 'CREATE SCHEMA IF NOT EXISTS public;'), 'Restore local schema without data');
  sql(`create table public.market_test_master(n integer,login text,code text,market text,id uuid default gen_random_uuid());
    insert into public.market_test_master(n,login,code,market) values ${master.map(([login, code, market], i) => `(${i + 1},${quote(login)},${quote(code)},${quote(market)})`).join(',')};
    create table public.market_test_actors(kind text,id uuid default gen_random_uuid());
    insert into public.market_test_actors(kind) values ('admin'),('supervisor'),('other_supervisor'),('field'),('new');
    insert into auth.users(id,email) select id,id::text||'@local.invalid' from public.market_test_actors union all select id,id::text||'@local.invalid' from public.market_test_master;
    insert into public.app_users(id,role,login_id,full_name) select id,case when kind='admin' then 'admin'::public.user_role when kind like '%supervisor' then 'supervisor'::public.user_role else 'promoter'::public.user_role end,'local-'||kind,'Synthetic '||kind from public.market_test_actors where kind<>'new';
    insert into public.app_users(id,role,login_id,full_name,is_active) select id,'promoter',login,'Synthetic user '||n,n<>1 from public.market_test_master;
    insert into public.promoters(user_id,promoter_code,supervisor_id) select id,'LOCAL-'||n,(select id from public.market_test_actors where kind=case when n<=101 then 'supervisor' else 'other_supervisor' end) from public.market_test_master;
    insert into public.promoters(user_id,promoter_code) select id,'LOCAL-FIELD' from public.market_test_actors where kind='field';
    insert into public.org_people(designation,employee_name,source_key,source_system,auth_user_id,state_raw,market_raw,area_raw) select 'PROMOTER','Synthetic user '||n,'LOCAL-'||n,'admin',id,'Maharashtra','Original city','Original area' from public.market_test_master;
    create table public.market_before_accounts as select * from public.app_users;
    create table public.market_before_profiles as select * from public.org_people;
    create table public.market_before_sales as select * from public.sales;
    create table public.market_before_spins as select * from public.spins;`, 'Create 202 mapping fixtures, actors and pre-migration snapshots');
  for (const filename of ['20261119000100_report_user_markets.sql', '20261119000200_require_new_field_user_market.sql']) {
    const migration = readFileSync(`supabase/migrations/${filename}`, 'utf8');
    sql(migration, `Apply ${filename}`);
    sql(migration, `Rerun ${filename}`);
  }
  sql(readFileSync('test/report-markets-postgres.sql', 'utf8'), 'Mapping, scope, permissions, immutability and onboarding checks');
  log.push('ALL CHECKS PASSED. No production database was contacted.');
} catch (error) {
  log.push(`FAILED: ${error.stack || error}`);
  console.error(log.at(-1));
  process.exitCode = 1;
} finally {
  writeFileSync('outputs/report-market-postgres-validation.log', log.join('\n').split('\n').map(line => line.trimEnd()).join('\n').trimEnd() + '\n');
}
