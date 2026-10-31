// All accounts, stock edits and spins below are isolated LOCAL test fixtures.
import {readFileSync,writeFileSync} from 'node:fs';
import {spawnSync,spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
const container='supabase_db_rio-spin-win-v7-sandbox';
const base=readFileSync('outputs/v8-harshraj-validation.log','utf8').match(/New LOCAL database: (rio_v8_harshraj_\d+)/)?.[1];
const db=`rio_four_atomic_${Date.now()}`;
const mp='supabase/migrations/20261031000300_enroll_four_users_v7_v8_atomic.sql';
const rp='supabase/rollbacks/20261031000300_restore_four_users_v7_v8_atomic.sql';
const migration=readFileSync(mp,'utf8'),rollback=readFileSync(rp,'utf8');
const ids=[1,2,3,4].map(n=>`a3110000-0000-0000-0000-${String(n).padStart(12,'0')}`);
const names=['TUSHAR SURESH AMRUTKAR','ASHISH RAMU KALWAL','SUJAL KALIDAS WANKHEDE','HARSHRAJ SHELAR'];
const log=[`New LOCAL database: ${db}`,`Source LOCAL database: ${base}`,...[mp,rp].map(p=>`${p} SHA256 (LF): ${createHash('sha256').update(readFileSync(p,'utf8').replace(/\r\n/g,'\n')).digest('hex')}`)];
function run(args,input){const r=spawnSync('docker',['exec','-i',container,...args],{input,encoding:'utf8',maxBuffer:50e6});if(r.error||r.status)throw Error(`${r.error||''}\n${r.stdout}\n${r.stderr}`);return r.stdout+r.stderr;}
function sql(s){return run(['psql','-X','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1','-At'],s).trim();}
function check(s,label){const out=sql(s);log.push(`\n${label}\n${out}`);console.log(`PASS: ${label}`);return out;}
function digest(){return sql(`select jsonb_build_object(
 'runtime',(select jsonb_object_agg(t,d) from (select t,(xpath('/table/row/md5/text()',query_to_xml(format('select md5(coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text)::text,''[]'')) from public.%I x',t),false,true,'')))[1]::text d from unnest(array['app_users','org_people','promoters','promoter_inventory','spins','prize_v8_daily_awards','prize_v7_settings','prize_v8_settings','campaign_allocations','prize_v7_allocations','campaigns','prize_configs','prize_config_items','inventory_movements']) t) a),
 'other_v7',(select md5(coalesce(jsonb_agg(to_jsonb(o) order by user_id)::text,'[]')) from public.prize_user_distribution_overrides o where user_id<>'${ids[0]}'),
 'other_v8',(select md5(coalesce(jsonb_agg(to_jsonb(o) order by user_id)::text,'[]')) from public.prize_v8_users o where user_id not in('${ids[1]}','${ids[2]}','${ids[3]}')),
 'functions',(select md5(string_agg(oid::text||prosrc,'' order by oid)) from pg_proc where pronamespace='public'::regnamespace));`);}
function members(){return sql(`select jsonb_build_object('v7',(select jsonb_agg(to_jsonb(x) order by user_id) from public.prize_user_distribution_overrides x),'v8',(select jsonb_agg(to_jsonb(x) order by user_id) from public.prize_v8_users x));`);}
function reject(s,pattern,label){const d=digest(),m=members();let err;try{sql(s);}catch(e){err=e;}if(!err||!pattern.test(String(err)))throw Error(`${label}: ${err||'unexpected success'}`);if(d!==digest()||m!==members())throw Error(`${label}: partial mutation`);log.push(`PASS: ${label}`);console.log(`PASS: ${label}`);}
function worker(s){return new Promise((resolve,reject)=>{const p=spawn('docker',['exec','-i',container,'psql','-X','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1','-At']);let out='';p.stdout.on('data',b=>out+=b);p.stderr.on('data',b=>out+=b);p.on('error',reject);p.on('close',c=>c?reject(Error(out)):resolve(out));p.stdin.end(s);});}
try{
 if(!base)throw Error('Validated local V8 fixture required');
 if(/create\s+(or\s+replace\s+)?function|truncate|update\s+public\.(promoter_inventory|spins|campaigns|prize_v[78]_settings|prize_v8_daily_awards)/i.test(migration))throw Error('Unexpected runtime mutation in enrollment source');
 run(['createdb','-U','postgres',db]);
 sql('create schema extensions; create extension pgcrypto with schema extensions; create extension pg_trgm with schema extensions; create extension plpgsql_check;');
 sql(run(['pg_dump','-U','postgres','-d',base,'--no-owner','--no-privileges','--schema=public','--schema=auth']).replace('CREATE SCHEMA public;','CREATE SCHEMA IF NOT EXISTS public;'));
 for(let j=0;j<4;j++)sql(`update public.app_users set full_name='LOCAL HISTORICAL '||id::text where regexp_replace(upper(full_name),'[^A-Z0-9]','','g')=regexp_replace('${names[j]}','[^A-Z0-9]','','g');
 insert into auth.users(id,email) values('${ids[j]}','four-atomic-${j}@local.invalid');
 insert into public.app_users(id,role,login_id,full_name) values('${ids[j]}','promoter','four-atomic-${j}','${names[j]}');
 insert into public.promoters(user_id,promoter_code) values('${ids[j]}','FOUR-ATOMIC-${j}');
 insert into public.org_people(designation,employee_name,auth_user_id,source_key,source_system,state_raw) values('PROMOTER','${names[j]}','${ids[j]}','four-atomic-${j}','test','Maharashtra');
 insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved) select '${ids[j]}',id,case code when 'SHADES' then 0 when 'SPEAKER' then ${[3,10,10,20][j]} when 'SNACK10' then ${j?100:82} else ${j?100:25} end,0 from public.prizes where code in('SNACK5','SNACK10','SHADES','SPEAKER');`);
 sql(`update public.v8_test_clock set at_value='2026-10-31T06:00:00Z' where at_value is not null;select public.v8_test_enable(true);
 update public.prize_v7_settings set enabled=true where campaign_id=(select id from public.campaigns where code='RSW-2026');
 insert into public.prize_user_distribution_overrides(user_id,mode,version,starts_on,expires_on,notes) values('${ids[0]}','no_snack5',7,'2026-10-29','2026-11-04','Earlier wrong category test');
 insert into public.prize_v8_users(user_id,reported_speakers,enabled,created_at) values('${ids[0]}',3,true,'2026-10-01'),('${ids[2]}',2,false,'2026-10-01'),('${ids[3]}',20,true,'2026-10-01');
 create table public.four_atomic_functions_before as select oid,prosrc from pg_proc where pronamespace='public'::regnamespace;`);
 const initial=members(),before=digest();
 check(migration,'Exact combined transaction; prior wrong Tushar category corrected');
 if(before!==digest())throw Error('Enrollment altered stock/history/accounts/settings/functions/unrelated memberships');
 const enrolled=members();check(migration,'Idempotent combined rerun');if(enrolled!==members()||before!==digest())throw Error('Rerun mutated runtime or memberships');
 check(`select public.v8_test_assert(public._v7_distribution_mode('${ids[0]}')='snacks','Tushar standard V7 effective');
 select public.v8_test_assert((select not v8_changed and v8_before=v8_after from public.prize_four_users_20261031_backup where target_no=1),'Tushar V8 preserved exactly');
 select public.v8_test_assert((select not v8_changed and v8_before=v8_after from public.prize_four_users_20261031_backup where target_no=4),'Already-enabled Harshraj unchanged exactly');
 select public.v8_test_assert((select enabled and reported_speakers=10 from public.prize_v8_users where user_id='${ids[2]}'),'Disabled prior Sujal row enabled');
 select public.v8_test_assert(not has_table_privilege('anon','public.prize_four_users_20261031_backup','SELECT') and not has_table_privilege('authenticated','public.prize_four_users_20261031_backup','SELECT'),'Private snapshot');
 create table public.four_atomic_results(user_id uuid,n integer,code text);`,'Effective memberships, enabled-Harshraj preservation, privacy');
 for(let j=0;j<4;j++)check(`do $$declare n int;r jsonb;s uuid;again jsonb;begin for n in 1..${j?20:50} loop
 s:=public.v8_test_sale('${ids[j]}');r:=public.v8_test_spin('${ids[j]}',s);
 insert into public.four_atomic_results values('${ids[j]}',n,r->'prize'->>'code');
 perform public.v8_test_assert((r->'prize'->>'code'='SPEAKER')=(n=3),'Speaker only on third spin');
 ${j?'':`if n<>3 then perform public.v8_test_assert((select distribution_version=7 and distribution_mode='snacks' from public.spins where id=(r->>'spin_id')::uuid),'Tushar ordinary draws use standard V7');end if;`}
 if n=3 then again:=public.v8_test_spin('${ids[j]}',s);perform public.v8_test_assert(again->>'spin_id'=r->>'spin_id','Speaker retry retains exact spin');end if;
 end loop;end $$;
 select public.v8_test_assert((select public._available('${ids[j]}',id)=${[3,10,10,20][j]}-1 from public.prizes where code='SPEAKER'),'One speaker deduction');
 select public.v8_test_assert((select public._available('${ids[j]}',id)=${j?100:82}-(select count(*) from public.four_atomic_results where user_id='${ids[j]}' and code='SNACK10') from public.prizes where code='SNACK10'),'Exact INR10 deductions');
 select public.v8_test_assert((select public._available('${ids[j]}',id)=${j?100:25}-(select count(*) from public.four_atomic_results where user_id='${ids[j]}' and code='SNACK5') from public.prizes where code='SNACK5'),'Exact INR5 deductions');`,`${names[j]} actual spin/handover and replay`);
 const played=digest();check(rollback+rollback,'Atomic rollback after real activity and rerun');if(played!==digest()||initial!==members())throw Error('Rollback failed exact restoration/runtime preservation');
 sql(`update public.app_users set full_name='Missing' where id='${ids[3]}';`);reject(migration,/found 0/,'Missing LAST account rolls back earlier three updates');
 sql(`update public.app_users set full_name='${names[3]}' where id='${ids[3]}';update public.app_users set full_name='${names[0]}' where id='${ids[1]}';`);reject(migration,/found 2/,'Duplicate identity rejected');
 sql(`update public.app_users set full_name='${names[1]}',is_active=false where id='${ids[1]}';`);reject(migration,/active field account/,'Inactive identity rejected');
 sql(`update public.app_users set is_active=true,role='supervisor' where id='${ids[1]}';`);reject(migration,/active field account/,'Wrong role rejected');
 sql(`update public.app_users set role='promoter' where id='${ids[1]}';update public.org_people set active=false where auth_user_id='${ids[3]}';`);reject(migration,/active organizational profile/,'Unlinked LAST account rejects all updates');
 sql(`update public.org_people set active=true where auth_user_id='${ids[3]}';update public.promoter_inventory i set reserved=on_hand from public.prizes p where p.id=i.prize_id and i.promoter_id='${ids[3]}' and p.code='SPEAKER';`);reject(migration,/no available speaker stock/,'Reserved LAST speaker stock rejects all updates');
 sql(`update public.promoter_inventory i set reserved=0 from public.prizes p where p.id=i.prize_id and i.promoter_id='${ids[3]}' and p.code='SPEAKER';update public.promoter_inventory i set reserved=on_hand from public.prizes p where p.id=i.prize_id and i.promoter_id='${ids[0]}' and p.code='SNACK5';`);reject(migration,/INR5 AND INR10/,'Missing Tushar snack stock rejected');
 sql(`update public.promoter_inventory i set reserved=0 from public.prizes p where p.id=i.prize_id and i.promoter_id='${ids[0]}' and p.code='SNACK5';select public.v8_test_enable(false);`);reject(migration,/effective V7\/V8 settings/,'Disabled V8 is never switched on');
 sql(`select public.v8_test_enable(true);update public.v8_test_clock set at_value='2026-11-05T06:00:00Z' where at_value is not null;`);reject(migration,/effective V7\/V8 settings/,'Expired V7 never extended');
 sql(`update public.v8_test_clock set at_value='2026-10-31T06:00:00Z' where at_value is not null;delete from public.prize_v8_users where user_id='${ids[3]}';`);
 const noHarshraj=members(),raceBefore=digest();const race=await Promise.all([worker(migration),worker(migration)]);log.push(`\nConcurrent combined enrollment\n${race.join('\n')}`);if(raceBefore!==digest())throw Error('Concurrent enrollment changed runtime');
 check(`select public.v8_test_assert((select count(*)=4 from public.prize_four_users_20261031_backup where rolled_back_at is null),'Exactly four concurrent snapshots');
 select public.v8_test_assert((select v8_changed from public.prize_four_users_20261031_backup where target_no=4),'Previously missing Harshraj enrolled');`,'Concurrent runs and missing-Harshraj enrollment');
 for(const id of ids)check(`do $$declare r jsonb;begin r:=public.v8_test_spin('${id}',public.v8_test_sale('${id}'));perform public.v8_test_assert(r->'prize'->>'code'<>'SPEAKER','No catch-up after reenrollment');end $$;`,'No duplicate daily award after re-enrollment');
 sql(`update public.prize_v8_users set enabled=false where user_id='${ids[3]}';`);reject(rollback,/changed after enrollment/,'Later LAST membership edit aborts whole rollback');
 const edited=members();check(migration,'Rerun preserves later administrator disable');if(edited!==members())throw Error('Later admin edit overwritten');
 sql(`update public.prize_v8_users set enabled=true where user_id='${ids[3]}';`);const after=digest();check(rollback,'Restore exact memberships after concurrency/activity');if(after!==digest()||noHarshraj!==members())throw Error('Final rollback differs');
 check(`select public.v8_test_assert(not exists(select 1 from public.four_atomic_functions_before b join pg_proc p on p.oid=b.oid where p.prosrc<>b.prosrc),'Every existing function body unchanged');`,'Existing function bodies unchanged');
 log.push('ALL FOUR-USER ATOMIC CHECKS PASSED. Production was not contacted.');console.log(log.at(-1));
}catch(e){log.push(`FAILED: ${e.stack}`);console.error(e);process.exitCode=1;}
finally{writeFileSync('outputs/four-users-atomic-validation.log',log.join('\n'));}
