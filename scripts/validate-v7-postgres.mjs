// Executes production SQL only in a newly created, isolated LOCAL Docker DB.
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const container = 'supabase_db_rio-spin-win-v7-sandbox';
const database = `rio_v7_validation_${Date.now()}`;
const log = [`Local PostgreSQL migration validation: ${new Date().toISOString()}`, `Container: ${container}`, `NEW isolated database: ${database}`];
const run = (args, input) => {
  const result = spawnSync('docker', ['exec', '-i', container, ...args], { input, encoding: 'utf8', maxBuffer: 30 * 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`${args.join(' ')}\n${result.error || ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout + result.stderr;
};
const sql = (source, label) => {
  const result = run(['psql', '-X', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], source);
  log.push(`\n=== ${label} ===\n${result}`);
  console.log(`${label}: PASS`);
  return result;
};
try {
  run(['createdb', '-U', 'postgres', database]);
  sql('create schema extensions; create extension pgcrypto with schema extensions; create extension pg_trgm with schema extensions;', 'Database bootstrap');
  const dump = run(['pg_dump', '-U', 'postgres', '-d', 'postgres', '--no-owner', '--no-privileges', '--schema=public', '--schema=auth']);
  sql(dump.replace('CREATE SCHEMA public;', 'CREATE SCHEMA IF NOT EXISTS public;'), 'Local schema and reference-data restore');
  // Restore supplied production V6 snapshot and the two known-safe helpers.
  sql(readFileSync(path.join(root, 'supabase/migrations/20261028001400_restore_v6_candidate_where.sql'), 'utf8'), 'Working production V6 baseline');
  sql(readFileSync(path.join(root, 'supabase/migrations/20261028001200_fix_activity_flag_upsert_where.sql'), 'utf8'), 'Working activity-flag baseline');
  sql(readFileSync(path.join(root, 'supabase/migrations/20261028001300_fix_allocation_upsert_where.sql'), 'utf8'), 'Working allocation baseline');
  sql("update public.prize_configs pc set version=6 where pc.is_active and pc.campaign_id=(select id from public.campaigns where code='RSW-2026');", 'Local reference config aligned to supplied live V6');
  const migration = readFileSync(path.join(root, 'supabase/migrations/20261029000100_static_v7_expiry_allocator.sql'), 'utf8');
  const requested = migration.split('insert into _v7_requested_20261029 values')[1].split(';')[0];
  sql(`create table public.v7_test_users(id uuid primary key, name text, mode text);\ninsert into public.v7_test_users select gen_random_uuid(),r.name,r.mode from (values ${requested}) r(name,mode);\ninsert into public.v7_test_users values ('a0000000-0000-0000-0000-000000000001','V7 TEST ADMIN','admin'),('a0000000-0000-0000-0000-000000000002','V6 CONTROL','control');\ninsert into auth.users(id,email) select id,id::text||'@local.invalid' from public.v7_test_users;\ninsert into public.app_users(id,role,login_id,full_name) select id,case when mode='admin' then 'admin'::public.user_role else 'promoter'::public.user_role end,id::text,name from public.v7_test_users;\ninsert into public.promoters(user_id,promoter_code) select id,'V7TEST-'||id::text from public.v7_test_users where mode<>'admin';`, '41-person fixture plus admin and V6 control');
  sql(migration, 'Production Version 7 migration execution');
  sql(migration, 'Migration rerun / idempotency');
  sql(readFileSync(path.join(root, 'test/v7-postgres.sql'), 'utf8'), 'V7 draws, V6 regression, stock, security, RPC and rollback tests');
  sql(readFileSync(path.join(root, 'supabase/rollbacks/20261029000100_disable_v7.sql'), 'utf8'), 'Published rollback script');
  sql(`do $$ begin if exists(select 1 from public.prize_v7_settings where enabled) then raise exception 'Rollback failed'; end if; end $$;`, 'Rollback verification');
  sql(migration, 'Rerun after rollback');
  sql(`do $$ begin if exists(select 1 from public.prize_v7_settings where enabled) then raise exception 'Rerun silently re-enabled V7'; end if; end $$;`, 'Migration rerun preserves disabled toggle');
  sql("update public.app_users set is_active=false where full_name='KARAN KALE';", 'Negative preflight fixture');
  try {
    run(['psql', '-X', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], migration);
    throw new Error('FAIL: missing allowlist user was accepted');
  } catch (error) {
    if (!String(error).includes('V7 allowlist validation failed')) throw error;
    log.push('\nPASS: Missing/inactive selected user rejected; migration transaction aborted.');
    console.log('Missing-user preflight rejection: PASS');
  }
  sql(`do $$ begin if exists(select 1 from public.prize_v7_settings where enabled) then raise exception 'Failed migration changed toggle'; end if; if (select count(*) from public.prize_user_distribution_overrides where expires_on='2026-11-04')<>41 then raise exception 'Failed migration changed overrides'; end if; end $$;`, 'Failed migration rolls back atomically');
  log.push('\nALL CHECKS PASSED. No production database was contacted.');
  console.log(`ALL CHECKS PASSED; database=${database}`);
} catch (error) {
  log.push(`\nFAILED: ${error.stack || error}`);
  console.error(log.at(-1));
  process.exitCode = 1;
} finally {
  mkdirSync(path.join(root, 'outputs'), { recursive: true });
  writeFileSync(path.join(root, 'outputs/v7-postgres-validation.log'), log.join('\n').replace(/[ \t]+$/gm, '').trimEnd() + '\n');
}
