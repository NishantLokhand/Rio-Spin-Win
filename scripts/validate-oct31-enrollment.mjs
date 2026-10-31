// Isolated local Docker fixtures only. Never connects to production.
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const container='supabase_db_rio-spin-win-v7-sandbox';
const base=readFileSync('outputs/v8-harshraj-validation.log','utf8').match(/New LOCAL database: (rio_v8_harshraj_\d+)/)?.[1];
const db=`rio_oct31_enroll_${Date.now()}`;
const paths=['supabase/migrations/20261031000100_enroll_tushar_amrutkar_special_v7.sql',
  'supabase/migrations/20261031000200_enroll_ashish_sujal_v8.sql',
  'supabase/rollbacks/20261031000100_restore_tushar_amrutkar_v7.sql',
  'supabase/rollbacks/20261031000200_restore_ashish_sujal_v8.sql'];
const [v7,v8,r7,r8]=paths.map(p=>readFileSync(p,'utf8'));
const ids=[1,2,3].map(n=>`a3100000-0000-0000-0000-${String(n).padStart(12,'0')}`);
const names=['TUSHAR SURESH AMRUTKAR','ASHISH RAMU KALWAL','SUJAL KALIDAS WANKHEDE'];
const log=[`New LOCAL database: ${db}`,`Source LOCAL database: ${base}`,
  ...paths.map(p=>`${p} SHA256: ${createHash('sha256').update(readFileSync(p,'utf8').replace(/\r\n/g,'\n')).digest('hex')}`)];
function run(args,input){const r=spawnSync('docker',['exec','-i',container,...args],{input,encoding:'utf8',maxBuffer:50e6});if(r.error||r.status)throw Error(`${r.error||''}\n${r.stdout}\n${r.stderr}`);return r.stdout+r.stderr;}
function sql(s){return run(['psql','-X','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1','-At'],s).trim();}
function check(s,label){log.push(`\n${label}\n${sql(s)}`);console.log(`PASS: ${label}`);}
function digest(){return sql(`select jsonb_build_object(
  'runtime',(select jsonb_object_agg(t,d) from (select t,(xpath('/table/row/md5/text()',query_to_xml(format('select md5(coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text)::text,''[]'')) from public.%I x',t),false,true,'')))[1]::text d from unnest(array['promoter_inventory','spins','prize_v8_daily_awards','prize_v7_settings','prize_v8_settings','campaign_allocations','prize_v7_allocations','campaigns','prize_configs','prize_config_items']) t) a),
  'other_v7',(select md5(coalesce(jsonb_agg(to_jsonb(o) order by user_id)::text,'[]')) from public.prize_user_distribution_overrides o where user_id<>'${ids[0]}'),
  'other_v8',(select md5(coalesce(jsonb_agg(to_jsonb(o) order by user_id)::text,'[]')) from public.prize_v8_users o where user_id not in('${ids[1]}','${ids[2]}')),
  'functions',(select md5(string_agg(oid::text||prosrc,'' order by oid)) from pg_proc where pronamespace='public'::regnamespace));`);}
function members(){return sql(`select jsonb_build_object('v7',(select jsonb_agg(to_jsonb(x) order by user_id) from public.prize_user_distribution_overrides x),'v8',(select jsonb_agg(to_jsonb(x) order by user_id) from public.prize_v8_users x));`);}
function reject(s,pattern,label){const d=digest(),m=members();let err;try{sql(s);}catch(e){err=e;}if(!err||!pattern.test(String(err)))throw Error(`${label}: ${err||'unexpected success'}`);if(d!==digest()||m!==members())throw Error(`${label}: partial mutation`);log.push(`PASS: ${label}`);console.log(`PASS: ${label}`);}
try {
  if(!base)throw Error('Validated local Harshraj fixture required');
  run(['createdb','-U','postgres',db]);
  sql('create schema extensions; create extension pgcrypto with schema extensions; create extension pg_trgm with schema extensions; create extension plpgsql_check;');
  sql(run(['pg_dump','-U','postgres','-d',base,'--no-owner','--no-privileges','--schema=public','--schema=auth']).replace('CREATE SCHEMA public;','CREATE SCHEMA IF NOT EXISTS public;'));
  for(let j=0;j<3;j++)sql(`update public.app_users set full_name='LOCAL HISTORICAL '||id::text where regexp_replace(upper(full_name),'[^A-Z0-9]','','g')=regexp_replace('${names[j]}','[^A-Z0-9]','','g');
    insert into auth.users(id,email) values('${ids[j]}','oct31-${j}@local.invalid');
    insert into public.app_users(id,role,login_id,full_name) values('${ids[j]}','promoter','oct31-${j}','${names[j]}');
    insert into public.promoters(user_id,promoter_code) values('${ids[j]}','OCT31-${j}');
    insert into public.org_people(designation,employee_name,auth_user_id,source_key,source_system,state_raw)
      values('PROMOTER','${names[j]}','${ids[j]}','oct31-${j}','test','Maharashtra');
    insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved) select '${ids[j]}',id,case when code='SHADES' then 0 when code='SPEAKER' then ${j?10:0} when code='SNACK10' then ${j?100:75} else ${j?100:0} end,0 from public.prizes where code in('SNACK5','SNACK10','SHADES','SPEAKER');`);
  sql(`update public.v8_test_clock set at_value='2026-10-31T06:00:00Z' where at_value is not null;
    select public.v8_test_enable(true); update public.prize_v7_settings set enabled=true where campaign_id=(select id from public.campaigns where code='RSW-2026');`);
  const before=digest(),initial=members();
  check(v7,'Tushar special V7 enrollment with 75 INR10, zero INR5');
  check(v8,'Ashish and Sujal V8 membership with 10 speakers each');
  if(before!==digest())throw Error('Enrollment altered runtime/functions/other memberships');
  const enrolled=members();check(v7+v8,'Idempotent enrollment');if(enrolled!==members()||before!==digest())throw Error('Rerun changed state');
  check(`select public.v8_test_assert(public._v7_distribution_mode('${ids[0]}')='no_snack5','Special V7 effective');
    create table public.oct31_results(user_id uuid,n int,code text);
    do $$declare j int;r jsonb;begin for j in 1..50 loop
      r:=public.v8_test_spin('${ids[0]}',public.v8_test_sale('${ids[0]}'));
      insert into public.oct31_results values('${ids[0]}',j,r->'prize'->>'code');
      perform public.v8_test_assert(r->'prize'->>'code'='SNACK10','No INR5 or shades without stock');
      perform public.v8_test_assert((select distribution_version=7 from public.spins where id=(r->>'spin_id')::uuid),'Uses V7');
    end loop;end $$;
    select public.v8_test_assert((select public._available('${ids[0]}',id)=25 from public.prizes where code='SNACK10'),'Exactly 50 handovers deducted from 75');`,'50 actual Tushar spin/handover calls');
  for(let j=1;j<3;j++)check(`do $$declare n int;r jsonb;s uuid;again jsonb;begin for n in 1..5 loop
    s:=public.v8_test_sale('${ids[j]}');r:=public.v8_test_spin('${ids[j]}',s);
    insert into public.oct31_results values('${ids[j]}',n,r->'prize'->>'code');
    perform public.v8_test_assert((r->'prize'->>'code'='SPEAKER')=(n=3),'Speaker only on third daily spin');
    if n=3 then again:=public.v8_test_spin('${ids[j]}',s);perform public.v8_test_assert(again->>'spin_id'=r->>'spin_id','Speaker retry same spin');end if;
    end loop;end $$;
    select public.v8_test_assert((select public._available('${ids[j]}',id)=9 from public.prizes where code='SPEAKER'),'Only one of ten speakers deducted');` ,`${names[j]} actual third-spin speaker and replay`);
  const played=digest();check(r8+r7+r8+r7,'Rollback after activity and idempotent rollback');
  if(played!==digest()||initial!==members())throw Error('Rollback changed runtime or did not restore memberships');
  sql(`update public.app_users set full_name='Missing' where id='${ids[2]}';`);reject(v8,/found 0/,'Missing second V8 account aborts whole batch');
  sql(`update public.app_users set full_name='${names[2]}' where id='${ids[2]}'; update public.app_users set full_name='${names[0]}' where id='${ids[1]}';`);reject(v7,/found 2/,'Ambiguous Tushar identity rejected');
  sql(`update public.app_users set full_name='${names[1]}' where id='${ids[1]}';update public.promoter_inventory i set reserved=on_hand from public.prizes p where p.id=i.prize_id and i.promoter_id='${ids[0]}' and p.code='SNACK10';`);reject(v7,/available INR10/,'Fully reserved INR10 rejected');
  sql(`update public.promoter_inventory i set reserved=0 from public.prizes p where p.id=i.prize_id and i.promoter_id='${ids[0]}' and p.code='SNACK10';update public.promoter_inventory i set reserved=on_hand from public.prizes p where p.id=i.prize_id and i.promoter_id='${ids[2]}' and p.code='SPEAKER';`);reject(v8,/no available speaker stock/,'Fully reserved second speaker account aborts whole batch');
  sql(`update public.promoter_inventory i set reserved=0 from public.prizes p where p.id=i.prize_id and i.promoter_id='${ids[2]}' and p.code='SPEAKER';`);
  check(v7+v8,'Re-enroll without resetting daily awards');
  for(let j=1;j<3;j++)check(`do $$declare r jsonb;begin r:=public.v8_test_spin('${ids[j]}',public.v8_test_sale('${ids[j]}'));perform public.v8_test_assert(r->'prize'->>'code'<>'SPEAKER','No catch-up after reenrollment');end $$;`,'No repeat speaker after re-enrollment');
  sql(`update public.prize_user_distribution_overrides set notes='Later edit' where user_id='${ids[0]}';`);reject(r7,/changed after enrollment/,'Rollback protects later V7 edit');
  sql(`update public.prize_v8_users set enabled=false where user_id='${ids[2]}';`);reject(r8,/changed after enrollment/,'Rollback protects later V8 edit atomically');
  const edited=members();check(v7+v8,'Reruns preserve later admin edits');if(edited!==members())throw Error('Later edits overwritten');
  check(readFileSync('supabase/repairs/20261031_verify_requested_v7_v8_users.sql','utf8'),'Read-only four-user status query');
  log.push('ALL OCT31 ENROLLMENT CHECKS PASSED. Production was not contacted.');console.log(log.at(-1));
}catch(e){log.push(`FAILED: ${e.stack}`);console.error(e);process.exitCode=1;}
finally{writeFileSync('outputs/oct31-enrollment-validation.log',log.join('\n'));}
