-- =====================================================================
-- RIO SPIN & WIN — 002 CORE FUNCTIONS
-- helpers · audit chain · immutability triggers · stock ledger · flags
-- =====================================================================

-- ---------------------------------------------------------------------
-- Time helpers (business day = India Standard Time)
-- ---------------------------------------------------------------------
create or replace function public.ist_now() returns timestamp
language sql stable as $$ select now() at time zone 'Asia/Kolkata' $$;

create or replace function public.ist_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- ---------------------------------------------------------------------
-- Identity helpers
-- ---------------------------------------------------------------------
create or replace function public.my_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.app_users where id = auth.uid() and is_active
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin','supervisor'), false)
$$;

-- can the current user see data belonging to promoter p?
create or replace function public.can_see_promoter(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin()
      or (p = auth.uid() and public.my_role() is not null)
      or exists (select 1 from public.promoters pr
                  where pr.user_id = p and pr.supervisor_id = auth.uid()
                    and public.my_role() = 'supervisor')
$$;

create or replace function public._require_promoter() returns public.app_users
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users;
begin
  select * into u from public.app_users where id = auth.uid();
  if u.id is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if not u.is_active then raise exception 'USER_DISABLED' using hint = 'Your account has been disabled. Contact your supervisor.'; end if;
  if u.role <> 'promoter' then raise exception 'PROMOTER_ONLY'; end if;
  return u;
end $$;

create or replace function public._require_staff() returns public.app_users
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users;
begin
  select * into u from public.app_users where id = auth.uid();
  if u.id is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if not u.is_active then raise exception 'USER_DISABLED'; end if;
  if u.role not in ('admin','supervisor') then raise exception 'STAFF_ONLY'; end if;
  return u;
end $$;

create or replace function public._require_admin() returns public.app_users
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users;
begin
  u := public._require_staff();
  if u.role <> 'admin' then raise exception 'ADMIN_ONLY'; end if;
  return u;
end $$;

-- ---------------------------------------------------------------------
-- AUDIT LOG (append-only, hash chained)
-- ---------------------------------------------------------------------
create or replace function public._audit_hash(p_prev text, p_at timestamptz, p_actor uuid,
    p_action text, p_entity text, p_entity_id text, p_details jsonb) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(
      coalesce(p_prev,'GENESIS') || '|' ||
      to_char(p_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US') || '|' ||
      coalesce(p_actor::text,'system') || '|' || p_action || '|' ||
      coalesce(p_entity,'') || '|' || coalesce(p_entity_id,'') || '|' ||
      coalesce(p_details::text,'{}'), 'sha256'), 'hex')
$$;

create or replace function public._write_audit(p_actor uuid, p_action text, p_entity text, p_entity_id text, p_details jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_prev text; v_at timestamptz := clock_timestamp(); v_role text;
begin
  perform pg_advisory_xact_lock(hashtext('rio_audit_chain'));
  select hash into v_prev from public.audit_logs order by id desc limit 1;
  select role::text into v_role from public.app_users where id = p_actor;
  insert into public.audit_logs(at, actor_id, actor_role, action, entity, entity_id, details, prev_hash, hash)
  values (v_at, p_actor, coalesce(v_role,'system'), p_action, p_entity, p_entity_id, coalesce(p_details,'{}'::jsonb), v_prev,
          public._audit_hash(v_prev, v_at, p_actor, p_action, p_entity, p_entity_id, coalesce(p_details,'{}'::jsonb)));
end $$;

create or replace function public.write_audit(p_action text, p_entity text, p_entity_id text, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  select public._write_audit(auth.uid(), p_action, p_entity, p_entity_id, p_details)
$$;

-- For the admin-users edge function (service role only)
create or replace function public.write_audit_as(p_actor uuid, p_action text, p_entity text, p_entity_id text, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  select public._write_audit(p_actor, p_action, p_entity, p_entity_id, p_details)
$$;

-- Admin tool: re-computes the chain; returns first broken id (null = intact)
create or replace function public.verify_audit_chain()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_prev text := null; v_n bigint := 0;
begin
  perform public._require_admin();
  for r in select * from public.audit_logs order by id loop
    v_n := v_n + 1;
    if r.prev_hash is distinct from v_prev
       or r.hash <> public._audit_hash(r.prev_hash, r.at, r.actor_id, r.action, r.entity, r.entity_id, r.details) then
      return jsonb_build_object('intact', false, 'broken_at_id', r.id, 'checked', v_n);
    end if;
    v_prev := r.hash;
  end loop;
  return jsonb_build_object('intact', true, 'checked', v_n);
end $$;

-- Block UPDATE / DELETE on append-only tables
create or replace function public._deny_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'IMMUTABLE_RECORD' using detail = TG_TABLE_NAME || ' rows cannot be ' || lower(TG_OP) || 'd';
end $$;

create trigger audit_logs_immutable before update or delete on public.audit_logs
  for each row execute function public._deny_mutation();
create trigger inventory_movements_immutable before update or delete on public.inventory_movements
  for each row execute function public._deny_mutation();
create trigger spins_no_delete before delete on public.spins
  for each row execute function public._deny_mutation();
create trigger sales_no_delete before delete on public.sales
  for each row execute function public._deny_mutation();

-- Spins: the prize and every snapshot field are frozen once written
create or replace function public._guard_spin_update() returns trigger
language plpgsql as $$
begin
  if (new.spin_code, new.sale_id, new.spin_no, new.campaign_id, new.promoter_id, new.biz_date, new.created_at,
      new.strategy, new.pool_id, new.slot_position, new.config_id, new.config_version,
      new.prize_id, new.prize_code, new.prize_name, new.prize_tier, new.prize_cost,
      new.original_prize_id, new.substituted)
     is distinct from
     (old.spin_code, old.sale_id, old.spin_no, old.campaign_id, old.promoter_id, old.biz_date, old.created_at,
      old.strategy, old.pool_id, old.slot_position, old.config_id, old.config_version,
      old.prize_id, old.prize_code, old.prize_name, old.prize_tier, old.prize_cost,
      old.original_prize_id, old.substituted) then
    raise exception 'IMMUTABLE_RECORD' using detail = 'Spin result fields cannot be changed';
  end if;
  if old.redemption_status <> 'pending' and new.redemption_status is distinct from old.redemption_status then
    raise exception 'IMMUTABLE_RECORD' using detail = 'Redemption already finalised';
  end if;
  return new;
end $$;
create trigger spins_guard before update on public.spins
  for each row execute function public._guard_spin_update();

-- Sales: snapshot fields frozen
create or replace function public._guard_sale_update() returns trigger
language plpgsql as $$
begin
  if (new.campaign_id, new.biz_date, new.created_at, new.promoter_id, new.promoter_code, new.promoter_name,
      new.state_id, new.state_name, new.territory_id, new.territory_name, new.tse_id, new.tse_code, new.tse_name,
      new.outlet_id, new.outlet_code, new.outlet_name, new.product_id, new.sku_code, new.product_name, new.quantity)
     is distinct from
     (old.campaign_id, old.biz_date, old.created_at, old.promoter_id, old.promoter_code, old.promoter_name,
      old.state_id, old.state_name, old.territory_id, old.territory_name, old.tse_id, old.tse_code, old.tse_name,
      old.outlet_id, old.outlet_code, old.outlet_name, old.product_id, old.sku_code, old.product_name, old.quantity) then
    raise exception 'IMMUTABLE_RECORD' using detail = 'Sale snapshot fields cannot be changed';
  end if;
  return new;
end $$;
create trigger sales_guard before update on public.sales
  for each row execute function public._guard_sale_update();

-- Generic master-data audit trigger
create or replace function public._audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id text; v_details jsonb;
begin
  if TG_OP = 'DELETE' then
    v_id := coalesce(to_jsonb(old)->>'id', to_jsonb(old)->>'user_id');
    v_details := jsonb_build_object('old', to_jsonb(old));
  elsif TG_OP = 'INSERT' then
    v_id := coalesce(to_jsonb(new)->>'id', to_jsonb(new)->>'user_id');
    v_details := jsonb_build_object('new', to_jsonb(new));
  else
    v_id := coalesce(to_jsonb(new)->>'id', to_jsonb(new)->>'user_id');
    select jsonb_build_object('changed', jsonb_object_agg(n.key, jsonb_build_object('from', o.value, 'to', n.value)))
      into v_details
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o using (key)
     where n.value is distinct from o.value and n.key <> 'updated_at';
    if v_details is null or v_details->'changed' is null then return new; end if;
  end if;
  perform public.write_audit('MASTER_' || TG_OP, TG_TABLE_NAME, v_id, v_details);
  return coalesce(new, old);
end $$;

create or replace function public._touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['states','territories','tses','outlets','app_users','promoters','products','prizes','campaigns']
  loop
    execute format('create trigger %I before update on public.%I for each row execute function public._touch_updated_at()', t||'_touch', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public._audit_row()', t||'_audit', t);
  end loop;
  foreach t in array array['campaign_states','campaign_territory_budgets','campaign_promoters','campaign_products']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public._audit_row()', t||'_audit', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- STOCK LEDGER — the only way stock balances change
-- ---------------------------------------------------------------------
create or replace function public._move_stock(p_promoter uuid, p_prize uuid, p_type public.movement_type,
    p_qty int, p_spin uuid, p_note text, p_reference text default null, p_release_reserved int default 0)
returns int language plpgsql security definer set search_path = public as $$
declare v_after int;
begin
  insert into public.promoter_inventory(promoter_id, prize_id, on_hand, reserved)
  values (p_promoter, p_prize, 0, 0) on conflict do nothing;

  update public.promoter_inventory
     set on_hand = on_hand + p_qty,
         reserved = reserved - p_release_reserved,
         updated_at = now()
   where promoter_id = p_promoter and prize_id = p_prize
  returning on_hand into v_after;

  insert into public.inventory_movements(promoter_id, prize_id, movement_type, qty, on_hand_after, spin_id, performed_by, reference, note)
  values (p_promoter, p_prize, p_type, p_qty, v_after, p_spin, auth.uid(), p_reference, p_note);
  return v_after;
end $$;

-- ---------------------------------------------------------------------
-- FLAGS
-- ---------------------------------------------------------------------
create or replace function public._flag(p_promoter uuid, p_campaign uuid, p_type text, p_severity text,
    p_reason text, p_details jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_key text := coalesce(p_promoter::text,'-') || ':' || p_type || ':' || public.ist_today()::text;
begin
  insert into public.activity_flags(promoter_id, campaign_id, flag_type, severity, reason, details, flag_date, flag_key)
  values (p_promoter, p_campaign, p_type, p_severity, p_reason, coalesce(p_details,'{}'::jsonb), public.ist_today(), v_key)
  on conflict (flag_key) do update
     set occurrences = public.activity_flags.occurrences + 1,
         reason      = excluded.reason,
         details     = excluded.details,
         status      = case when public.activity_flags.status = 'dismissed' then 'dismissed'::public.flag_status else 'open'::public.flag_status end,
         updated_at  = now();
end $$;

create or replace function public._rule(p_campaign uuid, p_key text, p_default numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select (flag_rules->>p_key)::numeric from public.campaigns where id = p_campaign), p_default)
$$;

create or replace function public._check_after_spin(p_spin uuid)
returns void language plpgsql security definer set search_path = public as $$
declare s public.spins; c public.campaigns; v_prev timestamptz; v_n int; v_hv int; v_t time;
begin
  select * into s from public.spins where id = p_spin;
  select * into c from public.campaigns where id = s.campaign_id;

  -- 1. spins too close together
  select max(created_at) into v_prev from public.spins
   where promoter_id = s.promoter_id and id <> s.id and created_at < s.created_at;
  if v_prev is not null and extract(epoch from (s.created_at - v_prev)) < public._rule(c.id,'min_seconds_between_spins',20) then
    perform public._flag(s.promoter_id, c.id, 'rapid_spins', 'medium',
      format('Spins %s seconds apart (minimum expected %s s)', round(extract(epoch from (s.created_at - v_prev))), public._rule(c.id,'min_seconds_between_spins',20)),
      jsonb_build_object('spin_code', s.spin_code));
  end if;

  -- 2. unusually high spin count
  select count(*) into v_n from public.spins where promoter_id = s.promoter_id and biz_date = s.biz_date;
  if v_n > public._rule(c.id,'max_spins_per_day',250) then
    perform public._flag(s.promoter_id, c.id, 'high_spin_count', 'medium',
      format('%s spins today (threshold %s)', v_n, public._rule(c.id,'max_spins_per_day',250)), jsonb_build_object('spins', v_n));
  end if;

  -- 3. concentration of high-value wins
  select count(*) into v_hv from public.spins
   where promoter_id = s.promoter_id and biz_date = s.biz_date
     and prize_cost >= public._rule(c.id,'high_value_cost',100);
  if v_hv > public._rule(c.id,'max_high_value_per_day',3) then
    perform public._flag(s.promoter_id, c.id, 'high_value_concentration', 'high',
      format('%s high-value prizes won today (threshold %s)', v_hv, public._rule(c.id,'max_high_value_per_day',3)),
      jsonb_build_object('high_value_wins', v_hv));
  end if;

  -- 4. outside working hours
  v_t := (s.created_at at time zone 'Asia/Kolkata')::time;
  if v_t < c.work_start or v_t > c.work_end then
    perform public._flag(s.promoter_id, c.id, 'outside_hours', 'low',
      format('Spin at %s IST — outside working hours %s–%s', to_char(v_t,'HH24:MI'), to_char(c.work_start,'HH24:MI'), to_char(c.work_end,'HH24:MI')),
      jsonb_build_object('spin_code', s.spin_code));
  end if;
end $$;

-- Periodic scan (call from dashboards or pg_cron): stale pending handovers
create or replace function public.run_flag_scan()
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0;
begin
  if auth.uid() is not null then perform public._require_staff(); end if;
  for r in
    select s.promoter_id, s.campaign_id, count(*) as n, min(s.spin_code) as first_code
      from public.spins s
     where s.redemption_status = 'pending'
       and s.created_at < now() - make_interval(mins => public._rule(s.campaign_id,'stale_pending_minutes',30)::int)
     group by 1,2
  loop
    perform public._flag(r.promoter_id, r.campaign_id, 'incomplete_transactions', 'medium',
      format('%s spin(s) not marked as handed over after %s min', r.n, public._rule(r.campaign_id,'stale_pending_minutes',30)),
      jsonb_build_object('pending', r.n, 'example_spin', r.first_code));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
