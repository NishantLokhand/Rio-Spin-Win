// Executes the exact guarded single-user Market correction in a NEW local DB.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const container='supabase_db_rio-spin-win-v7-sandbox',db=`rio_ritik_market_${Date.now()}`;
const base=readFileSync('outputs/report-market-postgres-validation.log','utf8').match(/Isolated database: (\w+)/)?.[1];
if(!base||!/^rio_market_validation_\d+$/.test(base))throw Error('Validated local Market fixture database required');
const migration=readFileSync('supabase/migrations/20261120000100_correct_ritik_kumar_report_market.sql','utf8');
const original=readFileSync('supabase/migrations/20261119000100_report_user_markets.sql','utf8');
const log=[`Local single-user Market validation: ${new Date().toISOString()}`,`New LOCAL database: ${db}`];
function run(args,input){const r=spawnSync('docker',['exec','-i',container,...args],{input,encoding:'utf8',maxBuffer:30e6});if(r.error||r.status)throw Error(`${r.error||''}\n${r.stdout}\n${r.stderr}`);return r.stdout+r.stderr;}
const sql=s=>run(['psql','-X','-U','postgres','-d',db,'-At','-v','ON_ERROR_STOP=1'],s).trim();
const pass=s=>{log.push('PASS: '+s);console.log('PASS: '+s);};
let admin,target;
function markets(){return JSON.parse(sql(`begin;select set_config('request.jwt.claim.sub','${admin}',true);select public.get_report_user_markets();commit;`).split('\n').find(l=>l.startsWith('[')));}
function data(){return sql(`select jsonb_build_object(
  'tables',(select jsonb_object_agg(t,h) from (select t,(xpath('/table/row/h/text()',query_to_xml(format(
  'select md5(coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text)::text,''[]'')) h from %I.%I x',s,t),false,true,'')))[1]::text h
  from (select schemaname s,tablename t from pg_tables where schemaname in ('public','auth'))x)y),
  'other_functions',(select md5(string_agg(oid::text||prosrc||coalesce(proacl::text,''),'' order by oid)) from pg_proc
    where pronamespace='public'::regnamespace and proname<>'get_report_user_markets'))`);}
function reject(input,pattern,label){const before=data(),body=sql("select prosrc from pg_proc where oid='public.get_report_user_markets()'::regprocedure");let e;
 try{sql(input);}catch(error){e=error;}assert(e&&pattern.test(String(e)),`${label}: ${e||'succeeded unexpectedly'}`);
 assert.equal(data(),before);assert.equal(sql("select prosrc from pg_proc where oid='public.get_report_user_markets()'::regprocedure"),body);pass(label+' refuses atomically');}
try{
 run(['createdb','-U','postgres','-T',base,db]);
 admin=sql("select id from public.market_test_actors where kind='admin'");
 target=sql("select id from public.app_users where login_id='6397823860'");
 sql(`update public.app_users set full_name='RITIK KUMAR' where id='${target}';
   update public.promoters set promoter_code='STAFF-6397823860' where user_id='${target}';
   update public.org_people set state_raw='UTTAR PRADESH',market_raw='MORADABAD',area_raw='Existing Moradabad area' where auth_user_id='${target}';`);
 const before=markets(),stable=data();assert.equal(before.find(r=>r.user_id===target).market,'NOIDA');
 log.push(sql(migration));const after=markets();
 assert.equal(after.find(r=>r.user_id===target).market,'MORADABAD');
 assert.deepEqual(after.filter(r=>r.user_id!==target),before.filter(r=>r.user_id!==target));assert.equal(data(),stable);
 pass('Only 6397823860 changes NOIDA to MORADABAD; all other report Markets stay identical');
 const other=sql("select id from public.app_users where login_id='6398077228'");
 assert.equal(after.find(r=>r.user_id===other).market,'NOIDA');
 assert.equal(sql(`select coalesce(market_override,market_raw) from public.org_people where auth_user_id='${target}'`),'MORADABAD');
 pass('Other Ritik remains NOIDA; target City/Area, user/auth records, sales, spins, stock, rules and other functions remain unchanged');
 sql(migration);assert.deepEqual(markets(),after);assert.equal(data(),stable);pass('Exact migration rerun is safe');
 sql(`begin;select set_config('request.jwt.claim.sub','${admin}',true);set local role authenticated;
   select public.get_report_user_markets();rollback;`);pass('Existing authenticated staff RPC still executes successfully');
 sql(`update public.app_users set full_name='OTHER PERSON' where id='${target}'`);
 reject(migration,/Expected one exact RITIK KUMAR/,'Wrong name');
 sql(`update public.app_users set full_name='RITIK KUMAR' where id='${target}';update public.promoters set promoter_code='OTHER-CODE' where user_id='${target}'`);
 reject(migration,/Expected one exact RITIK KUMAR/,'Wrong promoter code');
 sql(`update public.promoters set promoter_code='STAFF-6397823860' where user_id='${target}';
   create or replace function public.get_report_user_markets() returns jsonb language plpgsql stable security definer set search_path=public as $$begin perform public._require_staff();return '[]'::jsonb;end $$;`);
 reject(migration,/differs from the reviewed definition/,'Unexpected newer live lookup definition');
 sql(original);sql(migration);pass('Original static definition and corrected version can both be installed safely');
 pass('ALL CHECKS PASSED; no production database was contacted');
}catch(e){log.push('FAIL: '+e.stack);console.error(String(e).slice(-2500));process.exitCode=1;}
finally{writeFileSync('outputs/ritik-market-validation.log',log.join('\n')+'\n');}
