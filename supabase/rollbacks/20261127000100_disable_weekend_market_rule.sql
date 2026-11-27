-- Emergency database-side rollback for the temporary Thane/Mumbai rule.
-- This only disables the rule for future draws. It does not alter spins,
-- speaker awards, stock reservations, inventory, V6/V7/V8 settings, or history.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $rollback$
declare v_campaign uuid;
begin
  if to_regclass('public.prize_weekend_market_settings') is null then
    raise exception 'Weekend rule migration is not installed; no changes made';
  end if;
  select id into v_campaign from public.campaigns where code='RSW-2026';
  if v_campaign is null then raise exception 'RSW-2026 campaign not found; no changes made'; end if;

  -- Wait for any draw already using the temporary rule to finish.
  perform pg_advisory_xact_lock(hashtextextended('rio_weekend_market:'||v_campaign::text,0));
  update public.prize_weekend_market_settings
    set enabled=false,updated_at=clock_timestamp(),updated_by=null
    where campaign_id=v_campaign;
  if not found then raise exception 'Weekend rule settings row not found; no changes made'; end if;
end $rollback$;

notify pgrst,'reload schema';
commit;
