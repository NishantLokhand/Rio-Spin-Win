-- Run in the existing isolated V7 validation database, never production.
begin;
select set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
do $$
declare pid uuid; result jsonb; row_data jsonb; pcode text; expected integer;
begin
 select id into strict pid from public.app_users where full_name='KARAN KALE';
 insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved)
 select pid,p.id,450,6 from public.prizes p where p.code='SPEAKER'
 on conflict(promoter_id,prize_id) do update
 set on_hand=excluded.on_hand,reserved=excluded.reserved
 where public.promoter_inventory.promoter_id=excluded.promoter_id
   and public.promoter_inventory.prize_id=excluded.prize_id;
 update public.promoter_inventory pi set on_hand=105,reserved=5
 from public.prizes p where pi.promoter_id=pid and p.id=pi.prize_id and p.code='SNACK5';
 update public.promoter_inventory pi set on_hand=207,reserved=7
 from public.prizes p where pi.promoter_id=pid and p.id=pi.prize_id and p.code='SNACK10';
 update public.promoter_inventory pi set on_hand=309,reserved=9
 from public.prizes p where pi.promoter_id=pid and p.id=pi.prize_id and p.code='SHADES';
 result:=public.report_v7_expiry_users();
 select r into strict row_data from jsonb_array_elements(result) r where r->>'user_id'=pid::text;
 if (row_data->>'speakers_remaining')::integer is distinct from 444 then raise exception 'FAIL: speaker remaining column'; end if;
 if exists(select 1 from jsonb_array_elements(result) r where r->>'user_id'<>pid::text and (r->>'speakers_remaining')::integer is distinct from 0) then
  raise exception 'FAIL: missing speaker inventory must report zero remaining';
 end if;
 foreach pcode in array array['SNACK5','SNACK10','SHADES','SPEAKER'] loop
  expected:=case pcode when 'SNACK5' then 100 when 'SNACK10' then 200 when 'SHADES' then 300 else 444 end;
  if (row_data->'stock'->>pcode)::integer is distinct from expected then
   raise exception 'FAIL: remaining % expected %, returned %',pcode,expected,row_data->'stock'->>pcode;
  end if;
  raise notice 'PASS: % remaining = % (reserved quantities excluded)',pcode,expected;
 end loop;
 if jsonb_array_length(result)<>41 then raise exception 'FAIL: report user count changed'; end if;
 raise notice 'PASS: all 41 report users retained';
end $$;
rollback;
do $$ begin
 if exists (
  select 1 from v7_stock_function_snapshot f join pg_proc p on p.oid=f.oid where md5(p.prosrc)<>f.body_hash
 ) then raise exception 'FAIL: prize allocator or eligibility function changed'; end if;
 raise notice 'PASS: V6/V7 allocator, dispatch, eligibility and toggle function bodies unchanged';
 if exists(
  (select * from public.prize_v7_allocations except select * from v7_stock_counter_snapshot)
  union all (select * from v7_stock_counter_snapshot except select * from public.prize_v7_allocations)
 ) then raise exception 'FAIL: V7 allocation counters changed'; end if;
 raise notice 'PASS: allocation counters unchanged';
end $$;
