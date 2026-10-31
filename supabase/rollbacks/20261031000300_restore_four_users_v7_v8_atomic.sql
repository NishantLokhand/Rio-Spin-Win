-- Optional rollback of ONLY the rows changed by the combined four-user script.
-- Never restores stock, historical activity, counters, claims or global settings.
begin;
set local lock_timeout='5s';
set local statement_timeout='45s';
select pg_advisory_xact_lock(hashtext('rio_four_users_20261031'));
select pg_advisory_xact_lock(hashtext('rio_tushar_v7_20261031'));
select pg_advisory_xact_lock(hashtext('rio_v8_ashish_sujal_20261031'));
select pg_advisory_xact_lock(hashtext('rio_v8_harshraj_20261030'));
do $restore$
declare b record; v_current jsonb;
begin
  if to_regclass('public.prize_four_users_20261031_backup') is null then raise exception 'Combined enrollment snapshot missing; nothing changed'; end if;
  if (select count(*) from public.prize_four_users_20261031_backup)<>4 then raise exception 'Incomplete combined snapshot; nothing changed'; end if;
  for b in select * from public.prize_four_users_20261031_backup order by target_no for update loop
    if b.rolled_back_at is not null then continue; end if;
    perform 1 from public.app_users where id=b.user_id for update;
    if not found then raise exception 'Original account % no longer exists; entire rollback aborted',b.requested_name; end if;
    if b.v7_changed then
      select to_jsonb(o) into v_current from public.prize_user_distribution_overrides o where o.user_id=b.user_id for update;
      if v_current is distinct from b.v7_after then raise exception '% V7 membership changed after enrollment; entire rollback aborted',b.requested_name; end if;
      if b.v7_before is null then
        delete from public.prize_user_distribution_overrides where user_id=b.user_id;
      else
        insert into public.prize_user_distribution_overrides as existing
          select * from jsonb_populate_record(null::public.prize_user_distribution_overrides,b.v7_before)
        on conflict(user_id) do update set mode=excluded.mode,version=excluded.version,starts_on=excluded.starts_on,
          expires_on=excluded.expires_on,notes=excluded.notes,created_at=excluded.created_at where existing.user_id=excluded.user_id;
      end if;
    end if;
    if b.v8_changed then
      select to_jsonb(m) into v_current from public.prize_v8_users m where m.user_id=b.user_id for update;
      if v_current is distinct from b.v8_after then raise exception '% V8 membership changed after enrollment; entire rollback aborted',b.requested_name; end if;
      if b.v8_before is null then
        delete from public.prize_v8_users where user_id=b.user_id;
      else
        insert into public.prize_v8_users as existing
          select * from jsonb_populate_record(null::public.prize_v8_users,b.v8_before)
        on conflict(user_id) do update set reported_speakers=excluded.reported_speakers,enabled=excluded.enabled,
          created_at=excluded.created_at where existing.user_id=excluded.user_id;
      end if;
    end if;
    update public.prize_four_users_20261031_backup set rolled_back_at=now() where target_no=b.target_no;
  end loop;
end $restore$;
commit;
