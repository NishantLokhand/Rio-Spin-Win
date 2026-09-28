-- =====================================================================
-- RIO SPIN & WIN — 005 ROW LEVEL SECURITY, GRANTS, VIEWS
-- Principle: clients READ through RLS; every WRITE that matters goes
-- through a SECURITY DEFINER function that validates + audits it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Enable RLS everywhere
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Master data: everyone signed-in reads, admin writes (no hard deletes)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['states','territories','tses','outlets','products','prizes','campaigns',
                           'campaign_states','campaign_territory_budgets','campaign_products','campaign_promoters']
  loop
    execute format('create policy %I on public.%I for select to authenticated using (public.my_role() is not null)', t||'_read', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_admin())', t||'_admin_ins', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_admin()) with check (public.is_admin())', t||'_admin_upd', t);
    execute format('revoke delete, truncate on public.%I from authenticated', t);
  end loop;
  -- link tables may be deleted by admin
  foreach t in array array['campaign_states','campaign_territory_budgets','campaign_products','campaign_promoters']
  loop
    execute format('grant delete on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.is_admin())', t||'_admin_del', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------
create policy app_users_read on public.app_users for select to authenticated
  using (id = auth.uid() or public.is_admin()
         or (public.my_role() = 'supervisor' and role = 'promoter' and public.can_see_promoter(id)));
create policy app_users_admin_upd on public.app_users for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke insert, delete, truncate on public.app_users from authenticated;   -- created by edge function only

create policy promoters_read on public.promoters for select to authenticated
  using (public.can_see_promoter(user_id));
create policy promoters_admin_upd on public.promoters for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke insert, delete, truncate on public.promoters from authenticated;

-- ---------------------------------------------------------------------
-- Prize configuration & pools
-- ---------------------------------------------------------------------
create policy prize_configs_read on public.prize_configs for select to authenticated using (public.is_staff());
create policy prize_config_items_read on public.prize_config_items for select to authenticated using (public.is_staff());
create policy prize_pools_read on public.prize_pools for select to authenticated using (public.is_admin());
-- prize_pool_slots: NO policy at all → invisible to every API role, including admin
revoke all on public.prize_pool_slots from authenticated, anon;

-- ---------------------------------------------------------------------
-- Transactional data: own / supervised / all
-- ---------------------------------------------------------------------
create policy sales_read on public.sales for select to authenticated using (public.can_see_promoter(promoter_id));
create policy spins_read on public.spins for select to authenticated using (public.can_see_promoter(promoter_id));
create policy promoter_sessions_read on public.promoter_sessions for select to authenticated using (public.can_see_promoter(promoter_id));
create policy promoter_inventory_read on public.promoter_inventory for select to authenticated using (public.can_see_promoter(promoter_id));
create policy inventory_movements_read on public.inventory_movements for select to authenticated using (public.can_see_promoter(promoter_id));
create policy outlet_requests_read on public.outlet_requests for select to authenticated using (public.can_see_promoter(promoter_id));
create policy activity_flags_read on public.activity_flags for select to authenticated
  using (public.is_admin() or (promoter_id is not null and public.my_role() = 'supervisor' and public.can_see_promoter(promoter_id)));
create policy audit_logs_read on public.audit_logs for select to authenticated using (public.is_admin());
create policy sale_validations_read on public.sale_validations for select to authenticated using (public.is_admin());
create policy consumers_read on public.consumers for select to authenticated using (public.is_admin());

-- No direct writes to any of these — functions only
do $$
declare t text;
begin
  foreach t in array array['prize_configs','prize_config_items','prize_pools','sales','spins','promoter_sessions',
                           'promoter_inventory','inventory_movements','outlet_requests','activity_flags','audit_logs',
                           'sale_validations','consumers']
  loop
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
  end loop;
end $$;

grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;
revoke select on public.prize_pool_slots from authenticated;
grant insert, update on public.states, public.territories, public.tses, public.outlets, public.products, public.prizes,
  public.campaigns, public.campaign_states, public.campaign_territory_budgets, public.campaign_products,
  public.campaign_promoters, public.app_users, public.promoters to authenticated;
revoke insert on public.app_users, public.promoters from authenticated;

-- ---------------------------------------------------------------------
-- Reporting view (RLS of the caller applies)
-- ---------------------------------------------------------------------
create or replace view public.v_transactions with (security_invoker = true) as
select
  s.id                as transaction_id,
  sp.spin_code        as spin_id,
  c.code              as campaign_code,
  s.campaign_id,
  s.biz_date          as date,
  to_char(sp.created_at at time zone 'Asia/Kolkata', 'HH24:MI:SS') as time,
  s.state_name        as state,
  s.territory_name    as territory,
  s.tse_id, s.tse_code, s.tse_name,
  s.outlet_id, s.outlet_code, s.outlet_name, s.outlet_area as area, s.outlet_city as city, s.distributor,
  s.promoter_id, s.promoter_code, s.promoter_name, s.promoter_type,
  s.sku_code, s.product_name as sku, s.quantity,
  sp.prize_id, sp.prize_name, sp.prize_cost, sp.substituted,
  sp.redemption_status, sp.inventory_status,
  sp.handed_over_at, s.status as sale_status,
  coalesce(sp.device_ref, s.device_ref) as device_ref,
  s.state_id, s.territory_id, s.product_id,
  sp.config_version,
  sp.created_at       as spun_at
from public.sales s
join public.campaigns c on c.id = s.campaign_id
left join public.spins sp on sp.sale_id = s.id;

grant select on public.v_transactions to authenticated;

-- ---------------------------------------------------------------------
-- Function privileges: internal helpers are NOT callable from the API
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.my_role(), public.is_admin(), public.is_staff(), public.can_see_promoter(uuid),
  public.ist_today(), public.ist_now(),
  -- promoter
  public.set_work_context(uuid, text),
  public.record_sale(uuid, uuid, uuid, int, text, jsonb, timestamptz),
  public.play_spin(uuid, int, text),
  public.confirm_handover(uuid),
  public.my_pending_spin(),
  public.cancel_open_sale(uuid, text),
  public.get_promoter_home(),
  public.submit_outlet_request(text, text, text, text, uuid, text),
  -- supervisor / admin
  public.adjust_stock(uuid, uuid, public.movement_type, int, text, text),
  public.issue_stock_kit(uuid, jsonb, text),
  public.resolve_spin(uuid, text, text),
  public.review_outlet_request(uuid, boolean, uuid, text, text, text, text, text, text),
  public.review_flag(uuid, public.flag_status, text),
  public.raise_flag(uuid, text, text),
  public.report_summary(text, jsonb),
  public.dashboard_kpis(jsonb),
  public.run_flag_scan(),
  -- admin
  public.save_prize_config(uuid, uuid, int, jsonb, boolean, text),
  public.pool_status(uuid),
  public.import_outlets(jsonb),
  public.verify_audit_chain()
to authenticated;

grant execute on function public.write_audit_as(uuid, text, text, text, jsonb) to service_role;

-- Make future functions private by default too
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
