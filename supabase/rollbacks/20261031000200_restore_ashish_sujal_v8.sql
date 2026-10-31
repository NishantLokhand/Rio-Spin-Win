-- Restore only this batch’s previous V8 memberships. Preserve all current stock and history.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
-- Acquire before snapshot DDL so concurrent runs serialize before CREATE TABLE.
select pg_advisory_xact_lock(hashtext('rio_v8_ashish_sujal_20261031'));

do $restore$
declare b record; v_current jsonb;
begin
  if to_regclass('public.prize_v8_ashish_sujal_20261031_backup') is null then raise exception 'Batch snapshot missing; nothing changed'; end if;
  if (select count(*) from public.prize_v8_ashish_sujal_20261031_backup)<>2 then raise exception 'Incomplete batch snapshot; nothing changed'; end if;
  for b in select * from public.prize_v8_ashish_sujal_20261031_backup order by target_no for update loop
    if b.rolled_back_at is not null then continue; end if;
    perform 1 from public.app_users where id=b.user_id for update;
    if not found then raise exception 'Original account % no longer exists; nothing changed',b.requested_name; end if;
    select to_jsonb(m) into v_current from public.prize_v8_users m where m.user_id=b.user_id for update;
    if v_current is distinct from b.v8_after then raise exception '% membership changed after enrollment; entire rollback aborted',b.requested_name; end if;
    if b.v8_before is null then
      delete from public.prize_v8_users where user_id=b.user_id;
    else
      insert into public.prize_v8_users as existing
        select * from jsonb_populate_record(null::public.prize_v8_users,b.v8_before)
      on conflict(user_id) do update set reported_speakers=excluded.reported_speakers,enabled=excluded.enabled,created_at=excluded.created_at
        where existing.user_id=excluded.user_id;
    end if;
    update public.prize_v8_ashish_sujal_20261031_backup set rolled_back_at=now() where target_no=b.target_no;
  end loop;
end $restore$;
commit;
