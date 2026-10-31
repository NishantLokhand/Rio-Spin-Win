-- Restore only Tushar's prior V7 membership; retain current stock and history.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
select pg_advisory_xact_lock(hashtext('rio_tushar_v7_20261031'));
do $restore$
declare b record; v_current jsonb;
begin
  if to_regclass('public.prize_tushar_v7_20261031_backup') is null then raise exception 'Tushar snapshot missing; nothing changed'; end if;
  select * into b from public.prize_tushar_v7_20261031_backup where target_key='tushar_amrutkar' for update;
  if not found then raise exception 'Tushar snapshot missing; nothing changed'; end if;
  if b.rolled_back_at is not null then raise notice 'Already rolled back; nothing changed'; return; end if;
  perform 1 from public.app_users where id=b.user_id for update;
  if not found then raise exception 'Original Tushar account no longer exists; nothing changed'; end if;
  select to_jsonb(o) into v_current from public.prize_user_distribution_overrides o where user_id=b.user_id for update;
  if v_current is distinct from b.v7_after then raise exception 'Tushar membership changed after enrollment; inspect before rollback'; end if;
  if b.v7_before is null then
    delete from public.prize_user_distribution_overrides where user_id=b.user_id;
  else
    insert into public.prize_user_distribution_overrides as existing
      select * from jsonb_populate_record(null::public.prize_user_distribution_overrides,b.v7_before)
      on conflict(user_id) do update set mode=excluded.mode,version=excluded.version,starts_on=excluded.starts_on,
        expires_on=excluded.expires_on,notes=excluded.notes,created_at=excluded.created_at
      where existing.user_id=excluded.user_id;
  end if;
  update public.prize_tushar_v7_20261031_backup set rolled_back_at=now() where target_key='tushar_amrutkar';
end $restore$;
commit;
