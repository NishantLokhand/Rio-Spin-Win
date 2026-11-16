// Exact restoration SQL, executed in a new LOCAL PostgreSQL clone only.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const container='supabase_db_rio-spin-win-v7-sandbox',db=`rio_restore_ritesh_${Date.now()}`;
const uid='4ccab1c6-34b7-4076-bfc3-19320fdc5207';
const repair=readFileSync('supabase/repairs/20261116_restore_ritesh_tiwari.sql','utf8');
const log=[`Ritesh restoration validation: ${new Date().toISOString()}`,`NEW LOCAL database: ${db}`,
  `SQL SHA256 (LF): ${createHash('sha256').update(repair.replace(/\r\n/g,'\n')).digest('hex')}`];
function run(args,input){const r=spawnSync('docker',['exec','-i',container,...args],{input,encoding:'utf8',maxBuffer:30e6});if(r.error||r.status)throw Error(`${r.error||''}\n${r.stdout}\n${r.stderr}`);return r.stdout+r.stderr;}
const sql=s=>run(['psql','-X','-U','postgres','-d',db,'-At','-v','ON_ERROR_STOP=1'],s).trim();
function pass(s){log.push(`PASS: ${s}`);console.log(`PASS: ${s}`);}
function unchanged(){return sql(`select jsonb_build_object(
 'history',(select jsonb_object_agg(t,h) from (select t,(xpath('/table/row/h/text()',query_to_xml(format(
  'select md5(coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text)::text,''[]'')) h from public.%I x',t),false,true,'')))[1]::text h
  from unnest(array['sales','sale_items','spins','promoters','promoter_inventory','inventory_movements','prize_configs','prize_config_items',
  'campaign_allocations','prize_v7_settings','prize_v7_allocations','prize_v8_users','prize_v8_settings','prize_v8_daily_awards'])t)x),
 'functions',(select md5(string_agg(oid::text||prosrc,'' order by oid)) from pg_proc where pronamespace='public'::regnamespace),
 'others',(select md5(jsonb_agg(to_jsonb(x) order by id)::text) from public.app_users x where id<>'${uid}'),
 'other_org',(select md5(jsonb_agg(to_jsonb(x) order by id)::text) from public.org_people x where auth_user_id is distinct from '${uid}'),
 'other_auth',(select md5(jsonb_agg(to_jsonb(x) order by id)::text) from auth.users x where id<>'${uid}'),
 'password',(select encrypted_password from auth.users where id='${uid}')
);`);}
function state(){return sql(`select jsonb_build_object(
 'app',(select to_jsonb(x) from public.app_users x where id='${uid}'),
 'org',(select to_jsonb(x) from public.org_people x where auth_user_id='${uid}'),
 'auth',(select to_jsonb(x) from auth.users x where id='${uid}'),
 'deleted',(select to_jsonb(x) from public.deleted_field_users x where user_id='${uid}'),
 'excluded',(select to_jsonb(x) from public.reporting_excluded_users x where user_id='${uid}'),
 'audit',(select count(*) from public.audit_logs));`);}
function reject(input,pattern,label){const before=state(),other=unchanged();let error;try{sql(input);}catch(e){error=e;}
 assert(error&&pattern.test(String(error)),`${label}: ${error||'unexpected success'}`);assert.equal(state(),before);assert.equal(unchanged(),other);pass(label+' rejects atomically');}
try{
 run(['createdb','-U','postgres','-T','rio_v8_demo005_1793340787772',db]);
 sql(`insert into auth.users(id,email,banned_until,encrypted_password) values('${uid}','ritesh-local-test@invalid.test',null,'unchanged-local-fixture-hash');
  insert into public.app_users(id,role,full_name,login_id,is_active) values('${uid}','promoter','RITESH TIWARI','6392304061',true);
  insert into public.promoters(user_id,promoter_code) values('${uid}','STAFF-6392304061');
  insert into public.org_people(designation,employee_name,auth_user_id,source_key,source_system,state_raw,market_raw,area_raw,active)
   values('PROMOTER','RITESH TIWARI','${uid}','restore-ritesh-local','test','UTTAR PRADESH','PRAYAGRAJ','PRAYAGRAJ',true);
  insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved)
   select '${uid}',id,100,0 from public.prizes;
  select public.v8_test_spin('${uid}',public.v8_test_sale('${uid}'));
  update public.app_users set is_active=false where id='${uid}';
  update public.org_people set active=false where auth_user_id='${uid}';
  update auth.users set banned_until=now()+interval '100 years' where id='${uid}';
  insert into public.deleted_field_users(user_id,deleted_by,deleted_at) values('${uid}','a0000000-0000-0000-0000-000000000001','2026-10-28T09:00:00Z');
  insert into public.reporting_excluded_users(user_id,reason) values('${uid}','Requested field-user removal');`);
 const before=unchanged(),old=JSON.parse(state());
 log.push(sql(repair));const after=JSON.parse(state());
 assert.equal(after.app.is_active,true);assert.equal(after.org.active,true);assert.equal(after.auth.banned_until,null);
 assert.equal(after.deleted,null);assert.equal(after.excluded,null);assert.equal(unchanged(),before);
 const strip=(r,keys)=>Object.fromEntries(Object.entries(r).filter(([k])=>!keys.includes(k)));
 assert.deepEqual(strip(after.app,['is_active','updated_at']),strip(old.app,['is_active','updated_at']));
 assert.deepEqual(strip(after.org,['active','updated_at']),strip(old.org,['active','updated_at']));
 assert.deepEqual(strip(after.auth,['banned_until','updated_at']),strip(old.auth,['banned_until','updated_at']));
 assert.equal(sql(`select count(*) from public.audit_logs where action='FIELD_USER_RESTORED' and entity_id='${uid}'`),'1');
 pass('Exact repair reactivates one linked account, removes its old cutoff/exclusion and clears the authentication ban');
 pass('Password, all historical sales/spins/inventory, V6/V7/V8 rules/counters/functions and every other account remain unchanged');
 assert.equal(sql(`select details->'previous_removal'->>'deleted_at' from public.audit_logs where action='FIELD_USER_RESTORED' and entity_id='${uid}'`),'2026-10-28T09:00:00+00:00');
 pass('Audit keeps the original removal date and previous account, profile, ban and reporting flags');
 const stable=state();sql(repair);assert.equal(state(),stable);pass('Rerun is a complete no-op, including audit count and timestamps');
 for(const [set,restore,pattern,label] of [
  ["full_name='ANOTHER PERSON'","full_name='RITESH TIWARI'",/Exact RITESH/,'Wrong name'],
  ["login_id='0000000000'","login_id='6392304061'",/Exact RITESH/,'Wrong phone/login'],
  ["role='supervisor'","role='promoter'",/Exact RITESH/,'Wrong role'],
 ]){sql(`update public.app_users set ${set} where id='${uid}'`);reject(repair,pattern,label);sql(`update public.app_users set ${restore} where id='${uid}'`);}
 sql(`update public.org_people set market_raw='LUCKNOW',area_raw='LUCKNOW' where auth_user_id='${uid}'`);
 reject(repair,/location does not match/,'Wrong city');
 sql(`update public.org_people set market_raw='PRAYAGRAJ',area_raw='PRAYAGRAJ',state_raw='MAHARASHTRA' where auth_user_id='${uid}'`);
 reject(repair,/location does not match/,'Wrong state');
 sql(`update public.org_people set state_raw='UTTAR PRADESH' where auth_user_id='${uid}';
  insert into public.reporting_excluded_users(user_id,reason) values('${uid}','Other deliberate exclusion');`);
 reject(repair,/another reporting exclusion/,'Unrelated reporting exclusion');
 sql(`delete from public.reporting_excluded_users where user_id='${uid}'`);
 reject(repair.replaceAll(uid,'ffffffff-ffff-ffff-ffff-ffffffffffff'),/Exact RITESH/,'Missing exact account');
 pass('ALL LOCAL POSTGRESQL CHECKS PASSED; no live database was contacted');
}catch(e){log.push('FAIL: '+e.stack);console.error(String(e).slice(-3000));process.exitCode=1;}
finally{writeFileSync('outputs/restore-ritesh-validation.log',log.join('\n')+'\n');}
