// Tests the membership-only migration in a NEW local validation database.
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const container = 'supabase_db_rio-spin-win-v7-sandbox';
const base = readFileSync('outputs/v8-postgres-validation.log', 'utf8').match(/New LOCAL database: (rio_v8_validation_\d+)/)?.[1];
if (!base) throw new Error('Validated local V8 database is required');
const db = `rio_v8_pradeep_${Date.now()}`;
const log = [`Pradeep V8 membership test: ${new Date().toISOString()}`, `New LOCAL database: ${db}`];
function run(args, input) {
  const r = spawnSync('docker', ['exec','-i',container,...args], { input, encoding:'utf8', maxBuffer:30e6 });
  if (r.error || r.status) throw new Error(`${r.error || ''}\n${r.stdout}\n${r.stderr}`);
  return r.stdout+r.stderr;
}
function sql(input,label) {
  const out=run(['psql','-X','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1'],input);
  log.push(`\n=== ${label} ===\n${out}`); console.log(`${label}: PASS`); return out;
}
const migration=readFileSync('supabase/migrations/20261030000100_add_pradeep_rajbhar_to_v8.sql','utf8');
try {
  run(['createdb','-U','postgres',db]);
  sql('create schema extensions; create extension pgcrypto with schema extensions; create extension pg_trgm with schema extensions; create extension plpgsql_check;', 'Local bootstrap');
  const dump=run(['pg_dump','-U','postgres','-d',base,'--no-owner','--no-privileges','--schema=public','--schema=auth']);
  sql(dump.replace('CREATE SCHEMA public;','CREATE SCHEMA IF NOT EXISTS public;'), 'Restore local V8 fixtures');
  sql("update public.app_users set is_active=true where full_name='SUNIL KUMAR YADAV';", 'Restore active fixture after prior negative tests');
  sql(readFileSync('supabase/migrations/20261029000300_scheduled_v8_speakers.sql','utf8'), 'Restore V8 entry routes after prior recovery test');
  sql(`insert into auth.users(id,email) values('b0000000-0000-0000-0000-000000000013','pradeep@v8.local.invalid');
    insert into public.app_users(id,role,login_id,full_name) values('b0000000-0000-0000-0000-000000000013','promoter','pradeep-v8-test','PRADEEP RAJBHAR');
    insert into public.promoters(user_id,promoter_code) values('b0000000-0000-0000-0000-000000000013','V8-RAJBHAR-TEST');
    insert into public.org_people(designation,employee_name,auth_user_id,source_key,source_system,state_raw)
      values('PROMOTER','PRADEEP RAJBHAR','b0000000-0000-0000-0000-000000000013','v8-rajbhar-test','test','Maharashtra');
    insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved)
      select 'b0000000-0000-0000-0000-000000000013',id,case code when 'SPEAKER' then 10 when 'SHADES' then 0 else 100 end,0 from public.prizes where code in ('SNACK5','SNACK10','SHADES','SPEAKER');
    create table public.rajbhar_inventory_before as select * from public.promoter_inventory;
    create table public.rajbhar_settings_before as select * from public.prize_v8_settings;
    create table public.rajbhar_members_before as select * from public.prize_v8_users;
    create table public.rajbhar_functions_before as select p.oid,md5(p.prosrc) as body_hash from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public';`, 'Existing account with already-issued 10 speakers');
  sql(migration,'Pradeep membership migration');
  sql(migration,'Idempotent rerun');
  sql(`select public.v8_test_assert((select count(*)=13 and sum(reported_speakers)=96 from public.prize_v8_users where enabled),'13 selected users, reported total 96');
    select public.v8_test_assert(not exists((select * from public.promoter_inventory except select * from public.rajbhar_inventory_before) union all (select * from public.rajbhar_inventory_before except select * from public.promoter_inventory)),'No stock issued or changed');
    select public.v8_test_assert(not exists((select * from public.prize_v8_settings except select * from public.rajbhar_settings_before) union all (select * from public.rajbhar_settings_before except select * from public.prize_v8_settings)),'Global toggle and date settings unchanged');
    select public.v8_test_assert(not exists(select 1 from public.rajbhar_functions_before f join pg_proc p on p.oid=f.oid where md5(p.prosrc)<>f.body_hash),'All existing SQL function bodies unchanged');
    select public.v8_test_assert(not exists((select m.* from public.prize_v8_users m join public.rajbhar_members_before b on b.user_id=m.user_id except select * from public.rajbhar_members_before)),'Original 12 memberships unchanged');
    update public.v8_test_clock set at_value='2026-11-04T06:00:00Z' where at_value is not null;
    select public.v8_test_enable(true);
    do $$ declare pid uuid:='b0000000-0000-0000-0000-000000000013'; r jsonb; i int; begin
      for i in 1..4 loop
        r:=public.v8_test_spin(pid,public.v8_test_sale(pid));
        if i=3 then
          perform public.v8_test_assert(r->'prize'->>'code'='SPEAKER','Pradeep receives speaker on third daily spin');
        else
          perform public.v8_test_assert((select distribution_version=6 from public.spins where id=(r->>'spin_id')::uuid),'Pradeep ordinary spins retain existing V6 rules');
        end if;
      end loop;
      perform public.v8_test_assert((select pi.on_hand=9 and pi.reserved=0 from public.promoter_inventory pi join public.prizes p on p.id=pi.prize_id where pi.promoter_id=pid and p.code='SPEAKER'),'One speaker handed over: remaining 9, no duplicate issue');
    end $$;
    select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',false);
    select public.v8_test_assert(jsonb_array_length(public.report_v8_speaker_users(public.ist_today()))=13,'Tracking report includes 13 users');`, 'Membership isolation and real spin/handover verification');
  sql(migration,'Rerun after real speaker handover');
  sql(`select public.v8_test_assert((select pi.on_hand=9 and pi.reserved=0 from public.promoter_inventory pi join public.prizes p on p.id=pi.prize_id where pi.promoter_id='b0000000-0000-0000-0000-000000000013' and p.code='SPEAKER'),'Rerun does not replenish stock');
    select public.v8_test_assert((select count(*)=1 from public.prize_v8_daily_awards where user_id='b0000000-0000-0000-0000-000000000013'),'Existing daily award preserved');
    update public.app_users set is_active=false where id='b0000000-0000-0000-0000-000000000013';`, 'Existing stock and daily-award preservation');
  try { run(['psql','-X','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1'],migration); throw new Error('Inactive user accepted'); }
  catch(err) { if(!String(err).includes('Expected one exact active field account')) throw err; log.push('\nPASS: inactive/missing account is rejected safely.'); }
  log.push('\nALL PRADEEP MEMBERSHIP CHECKS PASSED. Production was not contacted.');
  console.log('ALL PRADEEP MEMBERSHIP CHECKS PASSED');
} catch(err) { log.push(`\nFAILED: ${err.stack || err}`); console.error(log.at(-1)); process.exitCode=1; }
finally { writeFileSync('outputs/v8-pradeep-validation.log',log.join('\n').replace(/[ \t]+$/gm,'').trimEnd()+'\n'); }
