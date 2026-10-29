// Production V8 SQL is executed only in a NEW local Docker validation DB.
import { spawnSync, spawn } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
const container = 'supabase_db_rio-spin-win-v7-sandbox';
const base = readFileSync('outputs/v7-postgres-validation.log', 'utf8').match(/NEW isolated database: (rio_v7_validation_\d+)/)?.[1];
if (!base) throw new Error('Validated local V7 database is required');
const database = `rio_v8_validation_${Date.now()}`;
const log = [`V8 PostgreSQL validation: ${new Date().toISOString()}`, `New LOCAL database: ${database}`, `Local V7 fixture source: ${base}`];
function run(args, input) {
  const r = spawnSync('docker', ['exec', '-i', container, ...args], { input, encoding: 'utf8', maxBuffer: 30e6 });
  if (r.error || r.status) throw new Error(`${r.error || ''}\n${r.stdout}\n${r.stderr}`);
  return r.stdout + r.stderr;
}
function sql(input, label) {
  const text = run(['psql', '-X', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], input);
  log.push(`\n=== ${label} ===\n${text}`); console.log(`${label}: PASS`); return text;
}
function worker(input) {
  return new Promise((resolve, reject) => {
    const p = spawn('docker', ['exec', '-i', container, 'psql', '-X', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '';
    p.stdout.on('data', (b) => { out += b; }); p.stderr.on('data', (b) => { err += b; });
    p.on('error', reject); p.on('close', (code) => code ? reject(new Error(out + err)) : resolve(out + err));
    p.stdin.end(input);
  });
}
try {
  run(['createdb', '-U', 'postgres', database]);
  sql('create schema extensions; create extension pgcrypto with schema extensions; create extension pg_trgm with schema extensions; create extension plpgsql_check;', 'Isolated database bootstrap');
  const dump = run(['pg_dump', '-U', 'postgres', '-d', base, '--no-owner', '--no-privileges', '--schema=public', '--schema=auth']);
  sql(dump.replace('CREATE SCHEMA public;', 'CREATE SCHEMA IF NOT EXISTS public;'), 'Copy validated local V7 schema and fixtures');
  const migration = readFileSync('supabase/migrations/20261029000300_scheduled_v8_speakers.sql', 'utf8');
  const users = migration.split('insert into _v8_requested_20261029 values')[1].split(';')[0];
  sql(`create table public.v8_test_users(id uuid primary key,name text,qty integer);
    insert into public.v8_test_users select coalesce((select id from public.app_users u where regexp_replace(upper(u.full_name),'[^A-Z0-9]','','g')=regexp_replace(r.name,'[^A-Z0-9]','','g')),gen_random_uuid()),r.name,r.qty from (values ${users}) r(name,qty);
    insert into auth.users(id,email) select id,id::text||'@v8.local.invalid' from public.v8_test_users on conflict(id) do nothing;
    insert into public.app_users(id,role,login_id,full_name) select id,'promoter',id::text,name from public.v8_test_users
      on conflict(id) do update set is_active=true where public.app_users.id=excluded.id;
    insert into public.promoters(user_id,promoter_code) select id,'V8TEST-'||id::text from public.v8_test_users on conflict(user_id) do nothing;
    insert into public.org_people(designation,employee_name,auth_user_id,source_key,source_system,state_raw,market_raw,area_raw)
      select 'PROMOTER',name,id,'V8TEST-'||id::text,'test','Maharashtra','TEST','TEST' from public.v8_test_users on conflict(auth_user_id) do nothing;
    update public.prize_v7_settings set enabled=true where campaign_id=(select id from public.campaigns where code='RSW-2026');
    create table public.v8_test_clock(at_value timestamptz); insert into public.v8_test_clock values('2026-10-30T06:00:00Z');
    grant select on public.v8_test_clock to authenticated;
    create or replace function public.ist_today() returns date language sql stable as $$ select (at_value at time zone 'Asia/Kolkata')::date from public.v8_test_clock $$;
    create table public.v8_function_snapshot as select oid,proname,md5(prosrc) as source_hash from pg_proc
      where proname in ('_draw_cumulative_prize_v6_20261029','_draw_prize_v7_20261029','_v7_distribution_mode','play_spin','confirm_handover');
    create table public.v8_inventory_snapshot as select * from public.promoter_inventory;`, '12 exact users, controlled IST clock, immutable-function snapshots');
  sql(migration, 'V8 migration execution');
  sql(migration, 'V8 migration rerun');
  sql(readFileSync('test/v8-postgres.sql', 'utf8'), 'V8 daily schedule, stock, retry, metadata, V6/V7 isolation and permissions');
  for (const [sameSale, day] of [[false, '2026-11-02'], [true, '2026-11-03']]) {
    const raceJson = run(['psql', '-X', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-c', `select public.v8_test_prepare_race('${day}',${sameSale})`]).trim();
    const race = JSON.parse(raceJson);
    const workerSql = (sale) => `begin; select set_config('request.jwt.claim.sub','${race.user}',true); select public.play_spin('${sale}',1,'v8-concurrent-test'); select pg_sleep(0.2); commit;`;
    const outputs = await Promise.all([worker(workerSql(race.sale1)), worker(workerSql(race.sale2))]);
    log.push(`\n=== ${sameSale ? 'Same sale concurrent replay' : 'Different sales concurrent draw'} ===\n${outputs.join('\n')}`);
    sql(`select public.v8_test_check_race('${day}',${sameSale});`, sameSale ? 'Concurrent retry reserves one speaker once' : 'Concurrent bills yield only one daily speaker');
  }
  sql(readFileSync('supabase/rollbacks/20261029000300_disable_v8.sql', 'utf8'), 'Normal SQL rollback');
  sql(`select public.v8_test_assert(not exists(select 1 from public.prize_v8_settings where enabled),'Normal rollback disabled V8');`, 'Normal rollback verification');
  sql(migration, 'Reapply after rollback');
  sql(`select public.v8_test_assert(not exists(select 1 from public.prize_v8_settings where enabled),'Rerun preserves disabled toggle');`, 'Rerun does not reactivate V8');
  sql(readFileSync('supabase/rollbacks/20261029000301_restore_pre_v8_routes.sql', 'utf8'), 'Emergency restoration of working entry routes');
  sql(`select public.v8_test_assert((select md5(regexp_replace(prosrc,'\\s','','g'))='d57efbacd4d8c4162a8d566fe5d2df37' from pg_proc where oid='public._draw_cumulative_prize(public.campaigns,public.prize_configs,uuid,text)'::regprocedure),'Exact original dispatcher restored');
    select public.v8_test_assert((select md5(regexp_replace(prosrc,'\\s','','g'))='3181b752940afd6b37864aa2cfc402ee' from pg_proc where oid='public._stock_problem(public.campaigns,public.prize_configs,uuid,text)'::regprocedure),'Exact original stock gate restored');`, 'Emergency recovery fingerprints');
  sql("update public.app_users set is_active=false where full_name='SUNIL KUMAR YADAV';", 'Negative user-match fixture');
  try { run(['psql','-X','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'], migration); throw new Error('Missing user accepted'); }
  catch (err) { if (!String(err).includes('V8 exact user match failed')) throw err; log.push('\nPASS: missing/inactive selected user aborts migration atomically.'); }
  log.push('\nALL V8 CHECKS PASSED. Production was not contacted.'); console.log('ALL V8 CHECKS PASSED');
} catch (error) { log.push(`\nFAILED: ${error.stack || error}`); console.error(log.at(-1)); process.exitCode = 1; }
finally { writeFileSync('outputs/v8-postgres-validation.log', log.join('\n').replace(/[ \t]+$/gm, '').trimEnd() + '\n'); }
