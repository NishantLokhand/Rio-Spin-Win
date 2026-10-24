-- Bulk issue selected prize quantities to all currently low-stock promoters
-- visible to an administrator. Uses adjust_stock so each
-- issue keeps the existing stock movements and audit trail.
create or replace function public.bulk_replenish_low_stock(p_items jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u public.app_users;
  v_entry jsonb;
  v_target record;
  v_prize uuid;
  v_qty int;
  v_after int;
  v_res jsonb;
  v_note text := coalesce(nullif(trim(p_note), ''), 'Bulk low-stock replenishment');
  v_batch uuid := gen_random_uuid();
  v_promoters uuid[] := '{}'::uuid[];
  v_items_issued jsonb := '[]'::jsonb;
  v_movement_count int := 0;
begin
  u := public._require_staff();
  if u.role <> 'admin' then raise exception 'ADMIN_ONLY'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'NO_REPLENISHMENT_ITEMS' using hint = 'Enter a positive quantity for at least one prize.';
  end if;

  -- Validate every submitted prize and quantity before changing any stock.
  for v_entry in select value from jsonb_array_elements(p_items) as entry(value) loop
    v_prize := nullif(v_entry->>'prize_id', '')::uuid;
    v_qty := nullif(v_entry->>'qty', '')::int;
    if v_prize is null or v_qty is null or v_qty <= 0 then
      raise exception 'INVALID_REPLENISHMENT_ITEM' using hint = 'Each quantity must be a positive whole number.';
    end if;
    if not exists (select 1 from public.prizes p where p.id = v_prize and p.is_active) then
      raise exception 'INVALID_PRIZE';
    end if;
  end loop;

  -- Lock the current low-stock rows so another stock action cannot make this
  -- batch act on an outdated threshold check. Quantities apply only to the
  -- prize types each promoter is currently low on.
  for v_target in
    select i.promoter_id, i.prize_id, i.on_hand, p.short_name, au.full_name
      from public.promoter_inventory i
      join public.prizes p on p.id = i.prize_id
      join public.app_users au on au.id = i.promoter_id
     where au.is_active and p.is_active
       and i.on_hand <= p.low_stock_threshold
       and public.can_see_promoter(i.promoter_id)
       and exists (
         select 1 from jsonb_array_elements(p_items) as submitted(value)
          where (submitted.value->>'prize_id')::uuid = i.prize_id
       )
     order by au.full_name, p.sort_order
     for update of i
  loop
    select coalesce(sum((submitted.value->>'qty')::int), 0)::int
      into v_qty
      from jsonb_array_elements(p_items) as submitted(value)
     where (submitted.value->>'prize_id')::uuid = v_target.prize_id;

    if v_qty > 0 then
      v_res := public.adjust_stock(v_target.promoter_id, v_target.prize_id, 'issue', v_qty, v_note,
                                   'bulk-low-stock:' || v_batch::text);
      v_after := (v_res->>'on_hand')::int;
      if not (v_target.promoter_id = any(v_promoters)) then
        v_promoters := array_append(v_promoters, v_target.promoter_id);
      end if;
      v_movement_count := v_movement_count + 1;
      v_items_issued := v_items_issued || jsonb_build_array(jsonb_build_object(
        'promoter_id', v_target.promoter_id, 'promoter', v_target.full_name,
        'prize_id', v_target.prize_id, 'prize', v_target.short_name,
        'quantity_added', v_qty, 'previous_on_hand', v_target.on_hand, 'on_hand_after', v_after
      ));
    end if;
  end loop;

  perform public.write_audit('STOCK_BULK_REPLENISH', 'promoter_inventory', v_batch::text,
    jsonb_build_object('batch_id', v_batch, 'promoters_updated', cardinality(v_promoters),
                       'movements', v_movement_count, 'note', v_note, 'items', v_items_issued));

  return jsonb_build_object('ok', true, 'batch_id', v_batch,
    'promoters_updated', cardinality(v_promoters), 'movements', v_movement_count,
    'items', v_items_issued);
end $$;

revoke execute on function public.bulk_replenish_low_stock(jsonb, text) from public, anon, authenticated;
grant execute on function public.bulk_replenish_low_stock(jsonb, text) to authenticated;
