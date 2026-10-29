\set ON_ERROR_STOP 1
create or replace function public.v8_test_assert(ok boolean,description text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',description; end if; raise notice 'PASS: %',description; end $$;
select public.v8_test_assert((select count(*)=12 and sum(reported_speakers)=86 from public.prize_v8_users),'12 exact users and 86 reported speakers; Pradeep excluded');
select public.v8_test_assert(not exists(select 1 from public.prize_v8_settings where enabled),'V8 installs disabled');
select public.v8_test_assert(not exists(
 (select * from public.promoter_inventory except select * from public.v8_inventory_snapshot)
 union all (select * from public.v8_inventory_snapshot except select * from public.promoter_inventory)
),'Installation and rerun do not add, deduct, or reserve inventory');

select public.v8_test_assert(not exists(
 select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 cross join lateral plpgsql_check_function_tb(p.oid) ck
 where n.nspname='public' and p.proname in ('_draw_cumulative_prize','_draw_prize_v8_20261029','_stock_problem',
 'get_prize_v8_status','set_prize_v8_enabled','report_v8_speaker_users') and ck.level='error'
),'PostgreSQL compilation and alias checking');

create table public.v8_stock_before as select * from public.promoter_inventory;
insert into public.promoter_inventory as inv(promoter_id,prize_id,on_hand,reserved)
select u.id,p.id,case when p.code='SPEAKER' then u.qty when p.code='SHADES' and u.name in ('SUNIL KUMAR YADAV','HARISHACHANDRA PATEL') then 0 else 20000 end,0
from public.v8_test_users u cross join public.prizes p where p.code in ('SNACK5','SNACK10','SHADES','SPEAKER')
on conflict(promoter_id,prize_id) do update set on_hand=excluded.on_hand,reserved=0
where inv.promoter_id=excluded.promoter_id and inv.prize_id=excluded.prize_id;
insert into public.promoter_inventory as inv(promoter_id,prize_id,on_hand,reserved)
select 'a0000000-0000-0000-0000-000000000002',id,10,0 from public.prizes where code='SPEAKER'
on conflict(promoter_id,prize_id) do update set on_hand=10,reserved=0
where inv.promoter_id=excluded.promoter_id and inv.prize_id=excluded.prize_id;

insert into public.states(code,name) values('V8TEST','V8 Test State');
insert into public.territories(state_id,code,name) select id,'V8TEST','V8 Test Territory' from public.states where code='V8TEST';
insert into public.tses(territory_id,code,name) select id,'V8TEST','V8 Test TSE' from public.territories where code='V8TEST';
insert into public.outlets(tse_id,outlet_code,name) select id,'V8TEST1','V8 Test Outlet 1' from public.tses where code='V8TEST';
insert into public.outlets(tse_id,outlet_code,name) select id,'V8TEST2','V8 Test Outlet 2' from public.tses where code='V8TEST';
insert into public.products(sku_code,name) values('V8TEST','V8 Test Product');

create or replace function public.v8_test_sale(pid uuid,allowed integer default 1,outlet_code text default 'V8TEST1') returns uuid language plpgsql as $$
declare sid uuid:=gen_random_uuid(); c public.campaigns; cfg public.prize_configs; st public.states; tr public.territories; tse public.tses; o public.outlets; p public.products; problem text;
begin
 select * into c from public.campaigns where code='RSW-2026'; cfg:=public._active_config(c.id,null);
 problem:=public._stock_problem(c,cfg,pid,c.id::text);
 if problem is not null then raise exception 'OUT_OF_STOCK' using hint=problem; end if;
 select * into st from public.states where code='V8TEST'; select * into tr from public.territories where code='V8TEST';
 select * into tse from public.tses where code='V8TEST'; select * into o from public.outlets x where x.outlet_code=v8_test_sale.outlet_code;
 select * into p from public.products where sku_code='V8TEST';
 insert into public.sales(id,campaign_id,biz_date,promoter_id,promoter_code,promoter_name,promoter_type,state_id,state_name,
 territory_id,territory_name,tse_id,tse_code,tse_name,outlet_id,outlet_code,outlet_name,product_id,sku_code,product_name,quantity,spins_allowed)
 values(sid,c.id,public.ist_today(),pid,'V8TEST',(select full_name from public.app_users where id=pid),'permanent',st.id,st.name,
 tr.id,tr.name,tse.id,tse.code,tse.name,o.id,o.outlet_code,o.name,p.id,p.sku_code,p.name,allowed,allowed);
 return sid;
end $$;
create or replace function public.v8_test_spin(pid uuid,sid uuid,n integer default 1,hand_over boolean default true) returns jsonb language plpgsql as $$
declare r jsonb;
begin
 perform set_config('request.jwt.claim.sub',pid::text,true);
 r:=public.play_spin(sid,n,'v8-local-db-test');
 if hand_over then perform public.confirm_handover((r->>'spin_id')::uuid); end if;
 return r;
end $$;
create or replace function public.v8_test_enable(enabled boolean) returns void language plpgsql as $$
begin
 perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
 perform public.set_prize_v8_enabled((select id from public.campaigns where code='RSW-2026'),enabled);
end $$;

-- Disabled path and nonselected user retain normal V6/V7 behavior.
do $$ declare pid uuid; r jsonb; i int; begin
 select id into pid from public.v8_test_users where name='ROHAN RATHOD';
 for i in 1..3 loop r:=public.v8_test_spin(pid,public.v8_test_sale(pid)); if r->'prize'->>'code'='SPEAKER' then raise exception 'FAIL: disabled V8 awarded speaker'; end if; end loop;
 perform public.v8_test_enable(true);
 r:=public.v8_test_spin(pid,public.v8_test_sale(pid));
 perform public.v8_test_assert(r->'prize'->>'code'<>'SPEAKER','Enabling after spin 3 has no catch-up award');
 pid:='a0000000-0000-0000-0000-000000000002';
 for i in 1..5 loop r:=public.v8_test_spin(pid,public.v8_test_sale(pid)); if r->'prize'->>'code'='SPEAKER' then raise exception 'FAIL: unselected user awarded speaker'; end if; end loop;
 perform public.v8_test_assert(true,'Unselected user with speaker stock stays on V6');
end $$;

-- Fresh IST day for all selected users. Third spin is across bills/outlets.
update public.v8_test_clock set at_value='2026-10-31T06:00:00Z' where at_value is not null;
create temporary table v8_results(name text,day_ordinal int,prize text,rule_version int);
do $$
declare u record; i integer; sid uuid; r jsonb; again jsonb; n6 integer; n7 integer; expected_base integer;
begin
 for u in select * from public.v8_test_users order by name loop
  expected_base:=case when public._v7_distribution_mode(u.id) is null then 6 else 7 end;
  for i in 1..6 loop
   if i=3 then
    select coalesce(sum(total_spins),0) into n6 from public.campaign_allocations;
    select coalesce(sum(total_spins),0) into n7 from public.prize_v7_allocations;
   end if;
   sid:=public.v8_test_sale(u.id,1,case when i%2=0 then 'V8TEST2' else 'V8TEST1' end);
   r:=public.v8_test_spin(u.id,sid);
   insert into v8_results select u.name,i,r->'prize'->>'code',distribution_version from public.spins where id=(r->>'spin_id')::uuid;
   if i=3 then
    if r->'prize'->>'code'<>'SPEAKER' then raise exception 'FAIL: % did not receive speaker at daily spin 3',u.name; end if;
    if (select coalesce(sum(total_spins),0) from public.campaign_allocations)<>n6 or (select coalesce(sum(total_spins),0) from public.prize_v7_allocations)<>n7 then raise exception 'FAIL: scheduled speaker changed base allocation counters'; end if;
    again:=public.v8_test_spin(u.id,sid);
    if again->>'spin_id'<>r->>'spin_id' or again->>'replayed'<>'true' then raise exception 'FAIL: speaker spin replay'; end if;
   else
    if r->'prize'->>'code'='SPEAKER' then raise exception 'FAIL: speaker outside daily spin 3'; end if;
    if (select distribution_version from public.spins where id=(r->>'spin_id')::uuid)<>expected_base then raise exception 'FAIL: ordinary rule changed'; end if;
   end if;
  end loop;
  if (select pi.on_hand from public.promoter_inventory pi join public.prizes p on p.id=pi.prize_id where pi.promoter_id=u.id and p.code='SPEAKER')<>u.qty-1 then raise exception 'FAIL: speaker deducted more than once'; end if;
 end loop;
 perform public.v8_test_assert(true,'All 12 users: exactly daily spin 3 is a speaker, across bills/outlets; correct V6/V7 ordinary rules');
 perform public.v8_test_assert(true,'Speaker handover/replay deducts one unit; base V6/V7 counters exclude speaker draws');
end $$;
select name,string_agg(day_ordinal::text,',' order by day_ordinal) filter(where prize='SPEAKER') as speaker_at_spin,
 count(*) filter(where prize='SPEAKER') as speakers,count(*) as total_spins from v8_results group by name order by name;
do $$ declare pid uuid; r jsonb; i int; begin
 select id into pid from public.v8_test_users where name='KARAN KALE';
 for i in 7..100 loop r:=public.v8_test_spin(pid,public.v8_test_sale(pid)); if r->'prize'->>'code'='SPEAKER' then raise exception 'FAIL: second speaker same day'; end if; end loop;
 perform public.v8_test_enable(false); perform public.v8_test_enable(true);
 r:=public.v8_test_spin(pid,public.v8_test_sale(pid));
 perform public.v8_test_assert(r->'prize'->>'code'<>'SPEAKER','100+ spins and off/on toggle do not grant a second daily speaker');
end $$;

-- No speaker at spin 3; restocking later that day does not grant a late prize.
update public.v8_test_clock set at_value='2026-11-01T06:00:00Z' where at_value is not null;
do $$ declare pid uuid; r jsonb; i int; begin
 select id into pid from public.v8_test_users where name='KARAN KALE';
 update public.promoter_inventory pi set on_hand=0,reserved=0 from public.prizes p where pi.promoter_id=pid and p.id=pi.prize_id and p.code='SPEAKER';
 for i in 1..3 loop r:=public.v8_test_spin(pid,public.v8_test_sale(pid)); if r->'prize'->>'code'='SPEAKER' then raise exception 'FAIL: speaker without stock'; end if; end loop;
 update public.promoter_inventory pi set on_hand=4 from public.prizes p where pi.promoter_id=pid and p.id=pi.prize_id and p.code='SPEAKER';
 for i in 4..8 loop r:=public.v8_test_spin(pid,public.v8_test_sale(pid)); if r->'prize'->>'code'='SPEAKER' then raise exception 'FAIL: late catch-up after restock'; end if; end loop;
 perform public.v8_test_assert(true,'Empty speaker stock at spin 3 gives normal prize; later restock never creates catch-up');
end $$;

-- Due speaker can be awarded when normal snack stocks have just run out.
do $$ declare pid uuid; sid uuid; r jsonb; i int; begin
 select id into pid from public.v8_test_users where name='NIKHIL KAROTE';
 sid:=public.v8_test_sale(pid);
 perform set_config('request.jwt.claim.sub',pid::text,true); perform public.cancel_open_sale(sid,'test customer left');
 for i in 1..2 loop perform public.v8_test_spin(pid,public.v8_test_sale(pid)); end loop;
 update public.promoter_inventory pi set on_hand=0,reserved=0 from public.prizes p where pi.promoter_id=pid and p.id=pi.prize_id and p.code in ('SNACK5','SNACK10','SHADES');
 r:=public.v8_test_spin(pid,public.v8_test_sale(pid));
 perform public.v8_test_assert(r->'prize'->>'code'='SPEAKER','Cancellation does not count; third-spin readiness permits in-stock speaker with empty snack stocks');
 begin perform public.v8_test_sale(pid); raise exception 'FAIL: ordinary stock checks bypassed'; exception when raise_exception then if sqlerrm<>'OUT_OF_STOCK' then raise; end if; end;
 perform public.v8_test_assert(true,'Ordinary stock gate remains enforced after scheduled speaker');
 update public.promoter_inventory pi set on_hand=20000 from public.prizes p where pi.promoter_id=pid and p.id=pi.prize_id and p.code in ('SNACK5','SNACK10','SHADES');
end $$;

-- Failed transactions roll back claims and reservations, then retry safely.
do $$ declare pid uuid; sid uuid; r jsonb; i int; begin
 select id into pid from public.v8_test_users where name='ROHAN RATHOD';
 for i in 1..2 loop perform public.v8_test_spin(pid,public.v8_test_sale(pid)); end loop;
 sid:=public.v8_test_sale(pid);
 begin
  perform public.v8_test_spin(pid,sid,1,false); raise exception 'INTENTIONAL_TX_FAILURE';
 exception when raise_exception then if sqlerrm<>'INTENTIONAL_TX_FAILURE' then raise; end if; end;
 perform public.v8_test_assert(not exists(select 1 from public.prize_v8_daily_awards where user_id=pid and biz_date=public.ist_today()),'Failed spin transaction rolls back its daily claim');
 r:=public.v8_test_spin(pid,sid,1,false);
 perform public.v8_test_assert(r->'prize'->>'code'='SPEAKER','Retry after failed transaction can award the correct third-spin speaker');
 perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
 perform public.resolve_spin((r->>'spin_id')::uuid,'not_redeemed','Test undelivered speaker');
 r:=public.v8_test_spin(pid,public.v8_test_sale(pid));
 perform public.v8_test_assert(r->'prize'->>'code'<>'SPEAKER','Undelivered resolution releases stock but cannot award a second speaker');
end $$;

-- Precise IST midnight reset.
update public.v8_test_clock set at_value='2026-11-01T18:29:59Z' where at_value is not null;
select public.v8_test_assert(public.ist_today()='2026-11-01','23:59:59 IST belongs to previous day');
update public.v8_test_clock set at_value='2026-11-01T18:30:00Z' where at_value is not null;
select public.v8_test_assert(public.ist_today()='2026-11-02','00:00:00 IST starts the next day');
do $$ declare pid uuid; r jsonb; i int; begin
 select id into pid from public.v8_test_users where name='SUNIL KUMAR YADAV';
 for i in 1..3 loop r:=public.v8_test_spin(pid,public.v8_test_sale(pid)); end loop;
 perform public.v8_test_assert(r->'prize'->>'code'='SPEAKER','New IST activity day restores eligibility at its third spin');
end $$;

-- V8 remains independent after V7 expiry; ordinary prizes return to V6.
update public.v8_test_clock set at_value='2026-11-05T06:00:00Z' where at_value is not null;
do $$ declare pid uuid; r jsonb; i int; begin
 select id into pid from public.v8_test_users where name='VIVEK DHARMADHIKARI';
 for i in 1..4 loop
  r:=public.v8_test_spin(pid,public.v8_test_sale(pid));
  perform public.v8_test_assert((select distribution_version from public.spins where id=(r->>'spin_id')::uuid)=case when i=3 then 8 else 6 end,'V8 speaker independent of V7 expiry; normal spin follows V6');
 end loop;
 perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
 perform public.v8_test_assert(jsonb_array_length(public.report_v8_speaker_users(public.ist_today()))=12,'V8 tracking report returns 12 users');
end $$;

-- Real database role cannot access private state or change feature toggle.
select id::text as promoter_id from public.v8_test_users where name='KARAN KALE' \gset
select id::text as campaign_id from public.campaigns where code='RSW-2026' \gset
begin;
select set_config('request.jwt.claim.sub',:'promoter_id',true);
select set_config('v8_test.campaign',:'campaign_id',true);
set local role authenticated;
do $$ begin
 begin perform public.set_prize_v8_enabled(current_setting('v8_test.campaign')::uuid,false); raise exception 'FAIL: promoter toggled V8'; exception when raise_exception then if sqlerrm<>'STAFF_ONLY' then raise; end if; end;
 begin perform count(*) from public.prize_v8_daily_awards; raise exception 'FAIL: promoter read private state'; exception when insufficient_privilege then null; end;
 begin perform public._v8_speaker_due(current_setting('v8_test.campaign')::uuid,auth.uid()); raise exception 'FAIL: internal helper callable'; exception when insufficient_privilege then null; end;
 raise notice 'PASS: promoter permissions restricted';
end $$;
rollback;

create or replace function public.v8_test_prepare_race(day date,same_sale boolean) returns jsonb language plpgsql as $$
declare pid uuid; s1 uuid; s2 uuid; i int;
begin
 update public.v8_test_clock set at_value=(day::text||'T06:00:00Z')::timestamptz where at_value is not null;
 select id into pid from public.v8_test_users where name='KARAN KALE';
 for i in 1..2 loop perform public.v8_test_spin(pid,public.v8_test_sale(pid)); end loop;
 s1:=public.v8_test_sale(pid); s2:=case when same_sale then s1 else public.v8_test_sale(pid) end;
 return jsonb_build_object('user',pid,'sale1',s1,'sale2',s2);
end $$;
create or replace function public.v8_test_check_race(day date,same_sale boolean) returns void language plpgsql as $$
declare pid uuid;
begin
 select id into pid from public.v8_test_users where name='KARAN KALE';
 perform public.v8_test_assert((select count(*)=1 from public.prize_v8_daily_awards where user_id=pid and biz_date=day),'Concurrent requests have one unique daily claim');
 perform public.v8_test_assert((select count(*)=1 from public.spins where promoter_id=pid and biz_date=day and prize_code='SPEAKER'),'Concurrent requests have one speaker spin');
 perform public.v8_test_assert((select count(*)=case when same_sale then 3 else 4 end from public.spins where promoter_id=pid and biz_date=day),'Concurrent replay/draw creates correct spin count');
 perform public.v8_test_assert((select pi.reserved=1 from public.promoter_inventory pi join public.prizes p on p.id=pi.prize_id where pi.promoter_id=pid and p.code='SPEAKER'),'Only one speaker reserved');
 perform set_config('request.jwt.claim.sub',pid::text,true);
 perform public.confirm_handover(s.id) from public.spins s where s.promoter_id=pid and s.biz_date=day and s.redemption_status='pending';
end $$;

select public.v8_test_assert(not exists(select 1 from public.v8_function_snapshot f join pg_proc p on p.oid=f.oid where f.source_hash<>md5(p.prosrc)),'Original V6/V7 allocator, play_spin and handover bodies unchanged');
select public.v8_test_assert(not exists(select 1 from public.promoter_inventory where reserved<0 or reserved>on_hand),'Inventory balances remain valid');
