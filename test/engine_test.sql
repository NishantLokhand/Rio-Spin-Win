-- Engine tests. Run after reset_db.sh:  psql ... -d rio -f test/engine_test.sql
\set ON_ERROR_STOP 1
\set P1 'a0000000-0000-0000-0000-000000000003'
\set P2 'a0000000-0000-0000-0000-000000000004'
\set ADMIN 'a0000000-0000-0000-0000-000000000001'
\set SUP 'a0000000-0000-0000-0000-000000000002'
\set SUPM 'a0000000-0000-0000-0000-000000000005'

create or replace function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false);
$$;

-- ============ 1. Admin/supervisor issues stock ============
begin;
set local role authenticated;
select pg_temp.as_user(:'SUP');
-- P1: plenty of everything; P2: everything except speaker
select public.issue_stock_kit(:'P1', '[{"prize_id":"50000000-0000-0000-0000-000000000001","qty":400},
  {"prize_id":"50000000-0000-0000-0000-000000000002","qty":100},{"prize_id":"50000000-0000-0000-0000-000000000003","qty":30},
  {"prize_id":"50000000-0000-0000-0000-000000000004","qty":10},{"prize_id":"50000000-0000-0000-0000-000000000005","qty":3}]', 'kit');
select public.issue_stock_kit(:'P2', '[{"prize_id":"50000000-0000-0000-0000-000000000001","qty":200},
  {"prize_id":"50000000-0000-0000-0000-000000000002","qty":50},{"prize_id":"50000000-0000-0000-0000-000000000003","qty":15},
  {"prize_id":"50000000-0000-0000-0000-000000000004","qty":5}]', 'kit no speaker');
commit;

-- ============ 2. P1 plays 230 spins ============
begin;
set local role authenticated;
select pg_temp.as_user(:'P1');
select public.set_work_context((select id from public.outlets where outlet_code='LKO-0001'), 'dev-test-1') ->> 'campaign' as ctx;
do $$
declare i int; sid uuid; r jsonb;
begin
  for i in 1..230 loop
    sid := gen_random_uuid();
    perform public.record_sale(sid, (select id from public.outlets where outlet_code='LKO-0001'),
                               '40000000-0000-0000-0000-000000000001', 2, 'dev-test-1');
    r := public.play_spin(sid);
    -- replay must return identical prize
    if (public.play_spin(sid)->'prize'->>'code') <> (r->'prize'->>'code') then raise exception 'IDEMPOTENCY BROKEN'; end if;
    perform public.confirm_handover((r->>'spin_id')::uuid);
  end loop;
end $$;
commit;

\echo '--- P1 first pool (must be exactly 152/34/10/3/1) ---'
select p.code, count(*) from public.spins s join public.prizes p on p.id = s.prize_id
 join public.prize_pools pp on pp.id = s.pool_id
 where s.promoter_id = :'P1' and pp.pool_no = 1 group by p.code order by 2 desc;
\echo '--- pools for P1 ---'
select pool_no, size, used, exhausted_at is not null as exhausted from public.prize_pools where scope_key = :'P1' order by pool_no;
\echo '--- P1 stock after (issued 400/100/30/10/3) ---'
select p.code, i.on_hand, i.reserved from public.promoter_inventory i join public.prizes p on p.id=i.prize_id where promoter_id=:'P1' order by p.sort_order;

-- ============ 3. Security checks as promoter ============
\echo '--- security: promoter cannot read slots / write spins ---'
begin; set local role authenticated; select pg_temp.as_user(:'P1');
do $$ begin
  begin perform * from public.prize_pool_slots limit 1; raise exception 'FAIL: slots readable';
  exception when insufficient_privilege then raise notice 'OK slots hidden'; end;
  begin update public.spins set prize_cost = 0; raise exception 'FAIL: spins updatable';
  exception when insufficient_privilege then raise notice 'OK spins not updatable'; end;
  begin perform * from public.prize_pools limit 1;
    if found then raise exception 'FAIL: promoter sees pools'; end if; raise notice 'OK pools invisible to promoter';
  end;
  begin perform public._new_pool(null,null,'promoter','x'); raise exception 'FAIL: internal fn callable';
  exception when insufficient_privilege then raise notice 'OK internal functions private'; end;
  begin perform public.adjust_stock('a0000000-0000-0000-0000-000000000003','50000000-0000-0000-0000-000000000005','issue',5);
    raise exception 'FAIL: promoter adjusted stock';
  exception when raise_exception then if sqlerrm = 'STAFF_ONLY' then raise notice 'OK promoter cannot adjust stock'; else raise; end if; end;
end $$;
commit;

-- ============ 4. Pending handover gate + cancel rules ============
begin; set local role authenticated; select pg_temp.as_user(:'P1');
do $$
declare sid uuid := gen_random_uuid(); sid2 uuid := gen_random_uuid(); r jsonb;
begin
  perform public.record_sale(sid, (select id from public.outlets where outlet_code='LKO-0002'), '40000000-0000-0000-0000-000000000002', 1);
  r := public.play_spin(sid);
  begin perform public.record_sale(sid2, (select id from public.outlets where outlet_code='LKO-0002'), '40000000-0000-0000-0000-000000000002', 1);
    raise exception 'FAIL: new sale while prize pending';
  exception when raise_exception then if sqlerrm = 'PENDING_HANDOVER' then raise notice 'OK pending gate'; else raise; end if; end;
  begin perform public.cancel_open_sale(sid); raise exception 'FAIL: cancelled spun sale';
  exception when raise_exception then if sqlerrm = 'SALE_ALREADY_SPUN' then raise notice 'OK cannot cancel after spin'; else raise; end if; end;
  begin perform public.play_spin(sid, 2); raise exception 'FAIL: second spin';
  exception when raise_exception then if sqlerrm = 'NO_SPINS_LEFT' then raise notice 'OK no second spin'; else raise; end if; end;
  if (public.my_pending_spin()->>'spin_id') <> (r->>'spin_id') then raise exception 'FAIL pending resume'; end if;
  raise notice 'OK pending spin resumable';
  perform public.confirm_handover((r->>'spin_id')::uuid);
end $$;
commit;

-- ============ 5. Out-of-stock DEFER: P2 has no speaker ============
begin; set local role authenticated; select pg_temp.as_user(:'P2');
do $$
declare i int; sid uuid; r jsonb; v_speaker int := 0;
begin
  for i in 1..199 loop
    sid := gen_random_uuid();
    perform public.record_sale(sid, (select id from public.outlets where outlet_code='LKO-0101'), '40000000-0000-0000-0000-000000000003', 1);
    r := public.play_spin(sid);
    if r->'prize'->>'code' = 'SPEAKER' then v_speaker := v_speaker + 1; end if;
    perform public.confirm_handover((r->>'spin_id')::uuid);
  end loop;
  if v_speaker > 0 then raise exception 'FAIL: speaker awarded without stock'; end if;
  raise notice 'OK 199 spins, no speaker awarded';
  -- only the speaker slot remains -> must block before customer spins
  begin
    perform public.record_sale(gen_random_uuid(), (select id from public.outlets where outlet_code='LKO-0101'), '40000000-0000-0000-0000-000000000003', 1);
    raise exception 'FAIL: sale allowed with only OOS prize left';
  exception when raise_exception then
    if sqlerrm = 'OUT_OF_STOCK' then raise notice 'OK blocked: only deferred speaker remains'; else raise; end if;
  end;
end $$;
commit;

-- supervisor replenishes speaker
begin; set local role authenticated; select pg_temp.as_user(:'SUP');
select public.adjust_stock(:'P2', '50000000-0000-0000-0000-000000000005', 'issue', 1, 'replenish');
commit;

begin; set local role authenticated; select pg_temp.as_user(:'P2');
do $$ declare sid uuid := gen_random_uuid(); r jsonb; begin
  perform public.record_sale(sid, (select id from public.outlets where outlet_code='LKO-0101'), '40000000-0000-0000-0000-000000000003', 1);
  r := public.play_spin(sid);
  if r->'prize'->>'code' <> 'SPEAKER' then raise exception 'FAIL: deferred speaker not awarded, got %', r->'prize'->>'code'; end if;
  raise notice 'OK deferred speaker awarded after replenishment';
  perform public.confirm_handover((r->>'spin_id')::uuid);
end $$;
commit;
\echo '--- P2 pool 1 composition (must be exactly 152/34/10/3/1) ---'
select p.code, count(*) from public.spins s join public.prizes p on p.id = s.prize_id
 join public.prize_pools pp on pp.id = s.pool_id where s.promoter_id = :'P2' and pp.pool_no = 1 group by p.code order by 2 desc;
select count(*) as deferral_audit_rows from public.audit_logs where action = 'PRIZE_DEFERRED';

-- ============ 6. Prize config economics ============
begin; set local role authenticated; select pg_temp.as_user(:'ADMIN');
do $$ begin
  begin
    perform public.save_prize_config('60000000-0000-0000-0000-000000000001', null, 100,
      '[{"prize_id":"50000000-0000-0000-0000-000000000001","quantity":90,"unit_cost":5},
        {"prize_id":"50000000-0000-0000-0000-000000000005","quantity":10,"unit_cost":200}]');
    raise exception 'FAIL: over-target config saved';
  exception when raise_exception then if sqlerrm = 'COST_ABOVE_TARGET' then raise notice 'OK warning enforced'; else raise; end if; end;
  begin
    perform public.save_prize_config('60000000-0000-0000-0000-000000000001', null, 100,
      '[{"prize_id":"50000000-0000-0000-0000-000000000001","quantity":90,"unit_cost":5}]');
    raise exception 'FAIL: size mismatch saved';
  exception when raise_exception then if sqlerrm = 'POOL_SIZE_MISMATCH' then raise notice 'OK size mismatch caught'; else raise; end if; end;
end $$;
-- Maharashtra-specific structure (state override) within target
select public.save_prize_config('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 100,
  '[{"prize_id":"50000000-0000-0000-0000-000000000001","quantity":80,"unit_cost":5},
    {"prize_id":"50000000-0000-0000-0000-000000000002","quantity":15,"unit_cost":10},
    {"prize_id":"50000000-0000-0000-0000-000000000003","quantity":4,"unit_cost":40},
    {"prize_id":"50000000-0000-0000-0000-000000000005","quantity":1,"unit_cost":200}]', false, 'MH v1');
select jsonb_pretty(public.pool_status('60000000-0000-0000-0000-000000000001') -> 'totals');
select public.verify_audit_chain();
commit;

-- ============ 7. Reports & scoping ============
begin; set local role authenticated; select pg_temp.as_user(:'SUP');
\echo '--- supervisor TSE report ---'
select jsonb_pretty(public.report_summary('tse', '{}'));
select jsonb_pretty(public.report_summary('prize', '{}'));
select (public.dashboard_kpis('{}')) -> 'totals' as kpis, (public.dashboard_kpis('{}')) -> 'budget' ->> 'remaining' as budget_remaining;
commit;
begin; set local role authenticated; select pg_temp.as_user(:'SUPM');
\echo '--- Mumbai supervisor must see 0 rows of Lucknow promoters ---'
select count(*) as visible_sales from public.sales;
select public.report_summary('promoter', '{}') as mumbai_view;
commit;
begin; set local role authenticated; select pg_temp.as_user(:'P1');
\echo '--- promoter home ---'
select jsonb_pretty(public.get_promoter_home() -> 'today');
commit;
\echo '--- flags ---'
select flag_type, severity, occurrences, reason from public.activity_flags order by created_at;
\echo '--- tamper test: direct superuser update of audit log must fail ---'
do $$ begin
  begin update public.audit_logs set action = 'X' where id = 1; raise exception 'FAIL';
  exception when raise_exception then if sqlerrm = 'IMMUTABLE_RECORD' then raise notice 'OK audit immutable'; else raise; end if; end;
end $$;
