\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u)::text, false); $$;
create or replace function pg_temp.spin_n(n int, outlet text) returns jsonb language plpgsql as $$
declare i int; sid uuid; r jsonb; res jsonb := '{}';
begin
  for i in 1..n loop
    sid := gen_random_uuid();
    perform public.record_sale(sid, (select id from public.outlets where outlet_code=outlet), '40000000-0000-0000-0000-000000000001', 1);
    r := public.play_spin(sid);
    res := jsonb_set(res, array[r->'prize'->>'code'], to_jsonb(coalesce((res->>(r->'prize'->>'code'))::int,0)+1));
    perform public.confirm_handover((r->>'spin_id')::uuid);
  end loop; return res; end $$;
-- stock
select pg_temp.as_user('a0000000-0000-0000-0000-000000000002');
set role authenticated;
select public.issue_stock_kit('a0000000-0000-0000-0000-000000000003', '[{"prize_id":"50000000-0000-0000-0000-000000000001","qty":2000},{"prize_id":"50000000-0000-0000-0000-000000000002","qty":500},{"prize_id":"50000000-0000-0000-0000-000000000003","qty":100},{"prize_id":"50000000-0000-0000-0000-000000000004","qty":2}]') is not null;
reset role;
\echo 'SUBSTITUTE mode, no speaker stock, shades only 2 → 200 spins'
update public.campaigns set oos_mode='substitute';
select pg_temp.as_user('a0000000-0000-0000-0000-000000000003'); set role authenticated;
select pg_temp.spin_n(200,'LKO-0001');
reset role;
select count(*) filter (where substituted) substituted, sum(prize_cost) cost from public.spins;
\echo 'WEIGHTED_RANDOM mode 1000 spins'
update public.campaigns set draw_strategy='weighted_random', oos_mode='defer';
select pg_temp.as_user('a0000000-0000-0000-0000-000000000003'); set role authenticated;
select pg_temp.spin_n(1000,'LKO-0001');
reset role;
\echo 'REGENERATE_NOW: config change voids open pool'
update public.campaigns set draw_strategy='controlled_pool', config_change_mode='regenerate_now', pool_scope='outlet';
select pg_temp.as_user('a0000000-0000-0000-0000-000000000003'); set role authenticated;
select pg_temp.spin_n(5,'LKO-0002');
reset role;
select pg_temp.as_user('a0000000-0000-0000-0000-000000000001'); set role authenticated;
select public.save_prize_config('60000000-0000-0000-0000-000000000001', null, 10, '[{"prize_id":"50000000-0000-0000-0000-000000000001","quantity":8,"unit_cost":5},{"prize_id":"50000000-0000-0000-0000-000000000002","quantity":2,"unit_cost":10}]');
reset role;
select pg_temp.as_user('a0000000-0000-0000-0000-000000000003'); set role authenticated;
select pg_temp.spin_n(10,'LKO-0002');
reset role;
select scope, pool_no, size, used, voided_at is not null voided, exhausted_at is not null exhausted from public.prize_pools where scope='outlet' order by created_at;
