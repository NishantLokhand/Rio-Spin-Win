\set ON_ERROR_STOP 1
create extension if not exists plpgsql_check;
create or replace function pg_temp.assert_true(ok boolean,description text)
returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',description; end if;
  raise notice 'PASS: %',description;
end $$;

select pg_temp.assert_true((select count(*)=41 from public.prize_user_distribution_overrides where expires_on='2026-11-04'),'41 exact selected users');
select pg_temp.assert_true((select md5(regexp_replace(prosrc,'\s','','g'))='b0a70bcf36948bccb14a96cc8d2d8a21' from pg_proc where oid='public._draw_cumulative_prize_v6_20261029(public.campaigns,public.prize_configs,uuid,text)'::regprocedure),'V6 source matches supplied production function');

-- Verify statements through PostgreSQL's PL/pgSQL checker, not regex counts.
-- V6 creates this temporary relation at runtime; expose its columns to the checker.
create temporary table _spin_candidates(p_id uuid,p_cost numeric,p_pct numeric,p_target numeric,p_actual integer,p_deficit numeric,p_weight numeric,p_constrained boolean);
select pg_temp.assert_true(not exists (
 select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 cross join lateral plpgsql_check_function_tb(p.oid) checks
 where n.nspname='public' and p.proname in (
  '_draw_prize_v7_20261029','_draw_cumulative_prize','_draw_cumulative_prize_v6_20261029',
  'get_prize_v7_status','set_prize_v7_enabled','report_v7_expiry_users') and checks.level='error'
),'PL/pgSQL compilation and alias resolution');

insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved)
select u.id,p.id,100000,0 from public.v7_test_users u cross join public.prizes p
where u.mode<>'admin' and p.code in ('SNACK5','SNACK10','SHADES')
on conflict(promoter_id,prize_id) do nothing;
update public.promoter_inventory inv set on_hand=0 where inv.prize_id=(select id from public.prizes where code='SHADES')
 and inv.promoter_id in (select id from public.v7_test_users where mode in ('snacks','control'));
update public.promoter_inventory inv set on_hand=0 where inv.prize_id=(select id from public.prizes where code='SNACK5')
 and inv.promoter_id in (select id from public.v7_test_users where mode='no_snack5');

create temporary table v7_draw_results(user_id uuid,mode text,spin_no integer,prize text);
create temporary table v6_counters_before as select * from public.campaign_allocations;
do $$
declare c public.campaigns; cfg public.prize_configs; u record; r record; p text; i integer;
begin
 select * into c from public.campaigns where code='RSW-2026';
 cfg:=public._active_config(c.id,null);
 for u in select distinct on (mode) id,mode from public.v7_test_users
    where mode in ('snacks','shades','no_snack5') order by mode,name loop
   for i in 1..5000 loop
     select * into r from public._draw_cumulative_prize(c,cfg,u.id,c.id::text);
     select code into p from public.prizes where id=r.prize_id;
     insert into v7_draw_results values(u.id,u.mode,i,p);
   end loop;
 end loop;
end $$;
select mode,prize,count(*) as wins,round(count(*)*100.0/5000,2) as percentage
 from v7_draw_results group by mode,prize order by mode,prize;
select pg_temp.assert_true(not exists(
 (select * from public.campaign_allocations except select * from v6_counters_before)
 union all (select * from v6_counters_before except select * from public.campaign_allocations)
),'15,000 V7 draws leave V6 counters unchanged');
select pg_temp.assert_true((select count(*) between 175 and 325 from v7_draw_results where mode='snacks' and prize='SNACK5'),'95/5 random mix, 5000 draws');
select pg_temp.assert_true(not exists(select 1 from v7_draw_results where mode='snacks' and prize='SHADES'),'No shades awarded without stock');
select pg_temp.assert_true((select count(*) between 200 and 400 from v7_draw_results where mode='shades' and prize='SNACK5'),'90/6/4 snack mix, 5000 draws');
select pg_temp.assert_true((select count(*) between 120 and 200 from v7_draw_results where mode='shades' and prize='SHADES'),'90/6/4 shade draws are random and capped');
select pg_temp.assert_true(not exists(select 1 from v7_draw_results where mode='no_snack5' and prize='SNACK5'),'No ₹5 prizes for the two no-₹5 users');
select pg_temp.assert_true((select count(*) between 120 and 200 from v7_draw_results where mode='no_snack5' and prize='SHADES'),'96/4 mix, 5000 draws');
select pg_temp.assert_true(not exists(
 select 1 from (select mode,spin_no,count(*) filter(where prize='SHADES') over(partition by mode order by spin_no) as shade_wins from v7_draw_results) q
 where q.shade_wins>ceil(q.spin_no*0.04)
),'Shade cap enforced at every prefix of the draw history');

create temporary table v7_counters_before as select * from public.prize_v7_allocations;
set client_min_messages=warning;
do $$
declare c public.campaigns; cfg public.prize_configs; pid uuid; i integer; r record;
begin
 select * into c from public.campaigns where code='RSW-2026'; cfg:=public._active_config(c.id,null);
 select id into pid from public.v7_test_users where mode='control';
 for i in 1..400 loop perform public._draw_cumulative_prize(c,cfg,pid,c.id::text); end loop;
end $$;
set client_min_messages=notice;
select pg_temp.assert_true((select a.total_spins=400 and coalesce((a.awarded->>(select id::text from public.prizes where code='SNACK5'))::int,0) between 298 and 302 from public.campaign_allocations a where a.campaign_id=(select id from public.campaigns where code='RSW-2026') and a.scope_key=a.campaign_id::text),'V6 no-shades control retains 75/25 cumulative mix');
select pg_temp.assert_true(not exists(
 (select * from public.prize_v7_allocations except select * from v7_counters_before)
 union all (select * from v7_counters_before except select * from public.prize_v7_allocations)
),'V6 draws leave V7 counters unchanged');

-- Stock gating/depletion, zero-stock blocking, and two users sharing a cohort.
do $$
declare c public.campaigns; cfg public.prize_configs; pid uuid; five uuid; ten uuid; shade uuid; r record; i integer; previous_count integer;
begin
 select * into c from public.campaigns where code='RSW-2026'; cfg:=public._active_config(c.id,null);
 select id into five from public.prizes where code='SNACK5'; select id into ten from public.prizes where code='SNACK10'; select id into shade from public.prizes where code='SHADES';
 select id into pid from public.v7_test_users where name='ANAND PARDE';
 select total_spins into previous_count from public.prize_v7_allocations where campaign_id=c.id and mode='shades';
 perform public._draw_cumulative_prize(c,cfg,pid,c.id::text);
 perform pg_temp.assert_true((select total_spins=previous_count+1 from public.prize_v7_allocations where campaign_id=c.id and mode='shades'),'Selected users share V7 counters for their applicable mix');
 update public.promoter_inventory set on_hand=reserved where promoter_id=pid and prize_id=shade;
 for i in 1..100 loop
  select * into r from public._draw_cumulative_prize(c,cfg,pid,c.id::text);
  if r.prize_id=shade then raise exception 'FAIL: depleted shade awarded'; end if;
 end loop;
 perform pg_temp.assert_true(true,'Depleted shades excluded across 100 draws');
 update public.promoter_inventory set on_hand=reserved where promoter_id=pid and prize_id=ten;
 begin perform public._draw_cumulative_prize(c,cfg,pid,c.id::text); raise exception 'FAIL: missing ₹10 stock allowed';
 exception when raise_exception then if sqlerrm<>'OUT_OF_STOCK' then raise; end if; end;
 update public.promoter_inventory set on_hand=reserved+10000 where promoter_id=pid and prize_id=ten;
 update public.promoter_inventory set on_hand=reserved where promoter_id=pid and prize_id=five;
 begin perform public._draw_cumulative_prize(c,cfg,pid,c.id::text); raise exception 'FAIL: missing required ₹5 stock allowed';
 exception when raise_exception then if sqlerrm<>'OUT_OF_STOCK' then raise; end if; end;
 update public.promoter_inventory set on_hand=reserved+10000 where promoter_id=pid and prize_id=five;
 select id into pid from public.v7_test_users where mode='no_snack5' order by name limit 1;
 update public.promoter_inventory set on_hand=reserved where promoter_id=pid and prize_id=shade;
 for i in 1..100 loop
  select * into r from public._draw_cumulative_prize(c,cfg,pid,c.id::text);
  if r.prize_id<>ten then raise exception 'FAIL: no-₹5/no-shades fallback'; end if;
 end loop;
 perform pg_temp.assert_true(true,'No-₹5 users fall back to 100% ₹10 once shades run out');
end $$;

-- Actual play_spin RPC: reservations, retry/idempotency, handover, reporting.
insert into public.states(code,name) values('V7TEST','V7 Test State');
insert into public.territories(state_id,code,name) select id,'V7TEST','V7 Test Territory' from public.states where code='V7TEST';
insert into public.tses(territory_id,code,name) select id,'V7TEST','V7 Test TSE' from public.territories where code='V7TEST';
insert into public.outlets(tse_id,outlet_code,name) select id,'V7TEST','V7 Test Outlet' from public.tses where code='V7TEST';
insert into public.products(sku_code,name) values('V7TEST','V7 Test Product');
insert into public.org_people(designation,employee_name,auth_user_id,source_key,source_system,state_raw,market_raw,area_raw)
select 'PROMOTER',u.name,u.id,'v7-test-'||u.id::text,'test','Maharashtra','TEST MARKET','TEST AREA'
from public.v7_test_users u where u.mode<>'admin';
do $$
declare c public.campaigns; pid uuid; sid uuid:=gen_random_uuid(); st public.states; tr public.territories; tse public.tses; outlet public.outlets; pr public.products; r jsonb; again jsonb; i integer; qty integer;
begin
 select * into c from public.campaigns where code='RSW-2026';
 select id into pid from public.v7_test_users where name='KARAN KALE';
 select * into st from public.states where code='V7TEST'; select * into tr from public.territories where state_id=st.id limit 1;
 select * into tse from public.tses where territory_id=tr.id limit 1; select * into outlet from public.outlets where tse_id=tse.id limit 1; select * into pr from public.products where sku_code='V7TEST';
 perform set_config('request.jwt.claim.sub',pid::text,true);
 insert into public.sales(id,campaign_id,biz_date,promoter_id,promoter_code,promoter_name,promoter_type,
   state_id,state_name,territory_id,territory_name,tse_id,tse_code,tse_name,outlet_id,outlet_code,outlet_name,
   product_id,sku_code,product_name,quantity,spins_allowed)
 values(sid,c.id,public.ist_today(),pid,'test','KARAN KALE','permanent',st.id,st.name,tr.id,tr.name,tse.id,tse.code,tse.name,outlet.id,outlet.outlet_code,outlet.name,pr.id,pr.sku_code,pr.name,10,10);
 for i in 1..10 loop
  r:=public.play_spin(sid,i,'v7-db-validation'); again:=public.play_spin(sid,i,'v7-db-validation');
  if r->>'spin_id'<>again->>'spin_id' or again->>'replayed'<>'true' then raise exception 'FAIL: spin replay'; end if;
  if not exists(select 1 from public.spins where id=(r->>'spin_id')::uuid and distribution_version=7 and distribution_mode='snacks') then raise exception 'FAIL: version stamp'; end if;
  select reserved into qty from public.promoter_inventory where promoter_id=pid and prize_id=(r->'prize'->>'id')::uuid;
  perform public.confirm_handover((r->>'spin_id')::uuid);
  if (select reserved from public.promoter_inventory where promoter_id=pid and prize_id=(r->'prize'->>'id')::uuid)<>qty-1 then raise exception 'FAIL: reservation release'; end if;
 end loop;
 perform pg_temp.assert_true((select count(*)=10 from public.spins where sale_id=sid and redemption_status='handed_over'),'10 real play_spin/handover RPCs, replay-safe, stamped V7');
 perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
 perform pg_temp.assert_true((public.get_prize_v7_status(c.id)->>'effective')::boolean,'Admin sees enabled V7 status');
 perform pg_temp.assert_true(jsonb_array_length(public.report_v7_expiry_users())=41,'Tracking report returns all 41 selected users');
 perform public.set_prize_v7_enabled(c.id,false);
 perform pg_temp.assert_true(public._v7_distribution_mode(pid) is null,'Admin disable routes selected user back to V6');
 perform public.set_prize_v7_enabled(c.id,true);
 update public.prize_v7_settings set expires_on=public.ist_today()-1,starts_on=public.ist_today()-2 where campaign_id=c.id;
 perform pg_temp.assert_true(public._v7_distribution_mode(pid) is null,'Expiry routes selected user back to V6');
 update public.prize_v7_settings set starts_on='2026-10-29',expires_on='2026-11-04' where campaign_id=c.id;
end $$;

-- ACL checks use the real authenticated DB role, including hostile callers.
select id::text as test_promoter from public.app_users where full_name='KARAN KALE' \gset
begin;
select set_config('request.jwt.claim.sub',:'test_promoter',true);
select set_config('rio_test.campaign',(select id::text from public.campaigns where code='RSW-2026'),true);
set local role authenticated;
do $$ declare c uuid:=current_setting('rio_test.campaign')::uuid; begin
 begin perform public.set_prize_v7_enabled(c,false); raise exception 'FAIL: promoter toggled V7';
 exception when raise_exception then if sqlerrm<>'STAFF_ONLY' then raise; end if; end;
 begin perform count(*) from public.prize_v7_allocations; raise exception 'FAIL: promoter read private counters'; exception when insufficient_privilege then null; end;
 begin perform public._v7_distribution_mode(auth.uid()); raise exception 'FAIL: promoter called internal mode function'; exception when insufficient_privilege then null; end;
 raise notice 'PASS: promoter cannot toggle V7, read private state, or call internal allocator helpers';
end $$;
rollback;

select pg_temp.assert_true(not exists(select 1 from public.promoter_inventory where reserved<0 or reserved>on_hand),'Inventory constraints preserved');
select pg_temp.assert_true((select is_active and version=6 from public.prize_configs where campaign_id=(select id from public.campaigns where code='RSW-2026') and is_active and state_id is null),'Base config remains active Version 6');
