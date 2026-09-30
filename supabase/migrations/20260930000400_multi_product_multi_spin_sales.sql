-- Mixed SKU bills and one server-authorized spin per purchased unit.
-- There is no campaign item-count cap; sale quantities remain PostgreSQL int values.

alter table public.campaigns alter column max_quantity_per_sale set default 2147483647;
update public.campaigns set max_quantity_per_sale = 2147483647 where max_quantity_per_sale < 2147483647;

create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id),
  sku_code text not null,
  product_name text not null,
  quantity int not null check (quantity > 0),
  created_at timestamptz not null default now(),
  unique (sale_id, product_id)
);
insert into public.sale_items(sale_id, product_id, sku_code, product_name, quantity)
select id, product_id, sku_code, product_name, quantity from public.sales
where product_id is not null and quantity > 0
on conflict (sale_id, product_id) do nothing;

alter table public.sale_items enable row level security;
drop policy if exists sale_items_read on public.sale_items;
create policy sale_items_read on public.sale_items for select to authenticated
  using (exists (select 1 from public.sales s where s.id = sale_id and public.can_see_promoter(s.promoter_id)));
revoke all on public.sale_items from anon;
revoke insert, update, delete, truncate on public.sale_items from authenticated;
grant select on public.sale_items to authenticated;

create or replace function public._guard_unfinished_spins_before_sale()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.sales s where s.promoter_id = new.promoter_id
       and s.status not in ('completed','cancelled') and s.spins_used > 0 and s.spins_used < s.spins_allowed) then
    raise exception 'SALE_IN_PROGRESS' using hint = 'Complete all customer spins and prize handovers before recording another bill.';
  end if;
  return new;
end $$;
drop trigger if exists sales_require_finished_spin_sequence on public.sales;
create trigger sales_require_finished_spin_sequence before insert on public.sales
for each row execute function public._guard_unfinished_spins_before_sale();
revoke all on function public._guard_unfinished_spins_before_sale() from public, anon, authenticated;

create or replace function public.record_basket_sale(
  p_sale_id uuid, p_outlet_id uuid, p_items jsonb,
  p_device_ref text default null, p_validation jsonb default '{}'::jsonb,
  p_client_time timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u public.app_users; v_total numeric; v_first_product uuid;
  v_state uuid; v_sale public.sales; v_campaign uuid; e jsonb; v_product uuid; v_qty int;
begin
  u := public._require_promoter();
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'EMPTY_BASKET' using hint = 'Add at least one Rio product to the bill.';
  end if;
  if jsonb_array_length(p_items) < 1 then raise exception 'EMPTY_BASKET' using hint = 'Add at least one Rio product to the bill.'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) x
      where coalesce(x->>'product_id','') = '' or coalesce(x->>'quantity','') !~ '^[0-9]+$'
         or case when coalesce(x->>'quantity','') ~ '^[0-9]+$' then (x->>'quantity')::numeric < 1 else false end) then
    raise exception 'INVALID_BASKET_ITEM' using hint = 'Each product needs a valid positive whole-number quantity.';
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) x group by x->>'product_id' having count(*) > 1) then
    raise exception 'DUPLICATE_BASKET_ITEM' using hint = 'Combine quantities for the same product.';
  end if;
  select sum((x->>'quantity')::numeric) into v_total from jsonb_array_elements(p_items) x;
  if v_total > 2147483647 then raise exception 'INVALID_QUANTITY' using hint = 'Combined bill quantity is too large.'; end if;
  v_first_product := (p_items->0->>'product_id')::uuid;

  -- Idempotent retry must match the original bill exactly; it cannot edit a recorded sale.
  select * into v_sale from public.sales where id = p_sale_id;
  if v_sale.id is not null then
    if v_sale.promoter_id <> u.id then raise exception 'SALE_NOT_FOUND'; end if;
    if v_sale.quantity <> v_total::int or v_sale.spins_allowed <> v_total::int
       or (select count(*) from public.sale_items where sale_id = p_sale_id) <> jsonb_array_length(p_items)
       or exists (select 1 from jsonb_array_elements(p_items) x where not exists (
          select 1 from public.sale_items si where si.sale_id = p_sale_id
            and si.product_id = (x->>'product_id')::uuid and si.quantity = (x->>'quantity')::int)) then
      raise exception 'SALE_IDEMPOTENCY_CONFLICT' using hint = 'This sale ID already belongs to a different bill.';
    end if;
    return jsonb_build_object('sale_id', p_sale_id, 'status', v_sale.status,
      'spins_allowed', v_sale.spins_allowed, 'spins_used', v_sale.spins_used, 'replayed', true);
  end if;

  -- A drawn prize must be handed over; then finish the current bill before another one.
  if exists (select 1 from public.spins where promoter_id = u.id and redemption_status = 'pending') then
    raise exception 'PENDING_HANDOVER' using hint = 'Hand over the previous prize before continuing.';
  end if;
  if exists (select 1 from public.sales where promoter_id = u.id and status not in ('completed','cancelled')
       and spins_used > 0 and spins_used < spins_allowed) then
    raise exception 'SALE_IN_PROGRESS' using hint = 'Complete all spins for the current customer first.';
  end if;

  -- record_sale performs the established outlet/campaign, stock, budget and validation checks.
  perform public.record_sale(p_sale_id, p_outlet_id, v_first_product, v_total::int,
      p_device_ref, coalesce(p_validation, '{}'::jsonb), p_client_time);
  select campaign_id, state_id into v_campaign, v_state from public.sales where id = p_sale_id and promoter_id = u.id;
  if v_campaign is null then raise exception 'SALE_NOT_FOUND'; end if;

  -- Validate every additional SKU against this campaign and outlet region. Any error rolls back the sale.
  for e in select value from jsonb_array_elements(p_items) loop
    v_product := (e->>'product_id')::uuid; v_qty := (e->>'quantity')::int;
    if not exists (select 1 from public.products p where p.id = v_product and p.is_active
          and (p.state_id is null or p.state_id = v_state)) then
      raise exception 'PRODUCT_NOT_ALLOWED' using hint = 'A selected SKU is inactive or unavailable in this region.';
    end if;
    if exists (select 1 from public.campaign_products where campaign_id = v_campaign)
       and not exists (select 1 from public.campaign_products where campaign_id = v_campaign and product_id = v_product) then
      raise exception 'PRODUCT_NOT_ALLOWED' using hint = 'A selected SKU is not part of this campaign.';
    end if;
    select sku_code, name into v_sale.sku_code, v_sale.product_name from public.products where id = v_product;
    insert into public.sale_items(sale_id, product_id, sku_code, product_name, quantity)
    values (p_sale_id, v_product, v_sale.sku_code, v_sale.product_name, v_qty)
    on conflict (sale_id, product_id) do update set quantity = excluded.quantity,
      sku_code = excluded.sku_code, product_name = excluded.product_name;
  end loop;
  update public.sales set quantity = v_total::int, spins_allowed = v_total::int
    where id = p_sale_id and promoter_id = u.id;
  perform public.write_audit('SALE_BASKET_RECORDED', 'sales', p_sale_id::text,
    jsonb_build_object('line_count', jsonb_array_length(p_items), 'total_units', v_total, 'spins_allowed', v_total));
  select * into v_sale from public.sales where id = p_sale_id;
  return jsonb_build_object('sale_id', p_sale_id, 'status', v_sale.status,
    'spins_allowed', v_sale.spins_allowed, 'spins_used', v_sale.spins_used, 'replayed', false);
end $$;

revoke all on function public.record_basket_sale(uuid, uuid, jsonb, text, jsonb, timestamptz) from public, anon;
grant execute on function public.record_basket_sale(uuid, uuid, jsonb, text, jsonb, timestamptz) to authenticated;

-- Preserve one row per spin while showing all SKUs on a mixed-SKU bill.
create or replace view public.v_transactions with (security_invoker = true) as
select
  s.id as transaction_id, sp.spin_code as spin_id, c.code as campaign_code, s.campaign_id,
  s.biz_date as date, to_char(sp.created_at at time zone 'Asia/Kolkata', 'HH24:MI:SS') as time,
  s.state_name as state, s.territory_name as territory, s.tse_id, s.tse_code, s.tse_name,
  s.outlet_id, s.outlet_code, s.outlet_name, s.outlet_area as area, s.outlet_city as city, s.distributor,
  s.promoter_id, s.promoter_code, s.promoter_name, s.promoter_type,
  coalesce(items.sku_codes, s.sku_code) as sku_code,
  coalesce(items.product_names, s.product_name) as sku,
  s.quantity, sp.prize_id, sp.prize_name, sp.prize_cost, sp.substituted,
  sp.redemption_status, sp.inventory_status, sp.handed_over_at, s.status as sale_status,
  coalesce(sp.device_ref, s.device_ref) as device_ref, s.state_id, s.territory_id, s.product_id,
  sp.config_version, sp.created_at as spun_at, coalesce(items.product_ids, array[s.product_id]) as product_ids
from public.sales s join public.campaigns c on c.id = s.campaign_id
left join public.spins sp on sp.sale_id = s.id
left join lateral (
  select string_agg(si.sku_code || ' × ' || si.quantity, ', ' order by si.sku_code) as sku_codes,
         string_agg(si.product_name || ' × ' || si.quantity, ', ' order by si.sku_code) as product_names,
         array_agg(si.product_id order by si.product_id) as product_ids
  from public.sale_items si where si.sale_id = s.id
) items on true;
grant select on public.v_transactions to authenticated;

-- Product filters must match any SKU line on a mixed basket.
create or replace function public._sales_where() returns text
language sql immutable as $f$
  select $$ s.status <> 'cancelled'
    and ($1->>'date_from' is null or s.biz_date >= ($1->>'date_from')::date)
    and ($1->>'date_to' is null or s.biz_date <= ($1->>'date_to')::date)
    and ($1->>'campaign_id' is null or s.campaign_id = ($1->>'campaign_id')::uuid)
    and ($1->>'state_id' is null or s.state_id = ($1->>'state_id')::uuid)
    and ($1->>'territory_id' is null or s.territory_id = ($1->>'territory_id')::uuid)
    and ($1->>'tse_id' is null or s.tse_id = ($1->>'tse_id')::uuid)
    and ($1->>'outlet_id' is null or s.outlet_id = ($1->>'outlet_id')::uuid)
    and ($1->>'promoter_id' is null or s.promoter_id = ($1->>'promoter_id')::uuid)
    and ($1->>'product_id' is null or exists (select 1 from public.sale_items si where si.sale_id = s.id and si.product_id = ($1->>'product_id')::uuid))
    and ($1->>'city' is null or s.outlet_city = $1->>'city')
    and ($1->>'distributor' is null or s.distributor = $1->>'distributor')
    and ($2 or s.promoter_id in (select user_id from public.promoters where supervisor_id = $3)) $$
$f$;
