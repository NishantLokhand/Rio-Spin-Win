-- Restore ONLY the verified existing Ritesh account. Run the complete file.
-- No password reset, account creation, stock issue, prize-rule or history rewrite.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
do $restore$
declare
  v_user uuid := '4ccab1c6-34b7-4076-bfc3-19320fdc5207';
  v_target public.app_users;
  v_person public.org_people;
  v_count integer;
  v_ban timestamptz;
  v_deleted jsonb;
  v_excluded jsonb;
begin
  select * into v_target from public.app_users where id=v_user for update;
  if v_target.id is null or v_target.login_id is distinct from '6392304061'
     or regexp_replace(upper(v_target.full_name),'[^A-Z0-9]','','g') is distinct from 'RITESHTIWARI'
     or v_target.role::text is distinct from 'promoter' then
    raise exception 'Exact RITESH TIWARI / 6392304061 account did not match; no changes committed';
  end if;
  select count(*) into v_count from public.org_people where auth_user_id=v_user;
  if v_count<>1 then
    raise exception 'Expected one linked organization record for Ritesh, found %; no changes committed',v_count;
  end if;
  select * into v_person from public.org_people where auth_user_id=v_user for update;
  if regexp_replace(upper(coalesce(v_person.state_raw,'')),'[^A-Z]','','g') not in ('UTTARPRADESH','UP')
     or not (
       regexp_replace(upper(coalesce(v_person.market_override,v_person.market_raw,'')),'[^A-Z]','','g')='PRAYAGRAJ'
       or regexp_replace(upper(coalesce(v_person.area_override,v_person.area_raw,'')),'[^A-Z]','','g')='PRAYAGRAJ'
     ) then
    raise exception 'Ritesh organization location does not match Prayagraj, Uttar Pradesh; no changes committed';
  end if;
  if not exists(select 1 from public.promoters where user_id=v_user) then
    raise exception 'Existing promoter record is missing; no changes committed';
  end if;
  select banned_until into v_ban from auth.users where id=v_user for update;
  if not found then raise exception 'Existing authentication account is missing; no changes committed';end if;
  select to_jsonb(d) into v_deleted from public.deleted_field_users d where d.user_id=v_user for update;
  select to_jsonb(e) into v_excluded from public.reporting_excluded_users e where e.user_id=v_user for update;
  if v_excluded is not null and v_excluded->>'reason' not in ('Requested field-user removal','Deleted field user') then
    raise exception 'Account has another reporting exclusion (%); review it before restoring; no changes committed',v_excluded->>'reason';
  end if;
  if v_target.is_active and v_person.active and v_ban is null and v_deleted is null and v_excluded is null then
    raise notice 'Ritesh is already active, linked and unbanned; no changes made';
    return;
  end if;

  -- Remove this account's old removal marker before the existing re-enable guard.
  delete from public.deleted_field_users where user_id=v_user;
  delete from public.reporting_excluded_users where user_id=v_user;
  update public.org_people set active=true,updated_at=now()
    where id=v_person.id and active is distinct from true;
  update auth.users set banned_until=null,updated_at=now()
    where id=v_user and banned_until is not null;
  update public.app_users set is_active=true,updated_at=now()
    where id=v_user and is_active is distinct from true;
  perform public._write_audit(auth.uid(),'FIELD_USER_RESTORED','app_users',v_user::text,
    jsonb_build_object('login_id',v_target.login_id,'full_name',v_target.full_name,
      'reason','Administrator requested return to active service on 16 November 2026',
      'previous_account_active',v_target.is_active,'previous_org_active',v_person.active,
      'previous_banned_until',v_ban,'previous_removal',v_deleted,
      'previous_reporting_exclusion',v_excluded,'history_preserved',true));
  raise notice 'RITESH TIWARI / 6392304061 restored. Password, sales, spins, stock, prize rules and other accounts are unchanged.';
end $restore$;
commit;

-- Verify the result without modifying anything further.
select u.full_name,u.login_id,u.is_active,p.active as organization_active,
  p.state_raw,p.market_raw as city,
  a.banned_until is null as login_unbanned,
  exists(select 1 from public.deleted_field_users d where d.user_id=u.id) as marked_deleted,
  exists(select 1 from public.reporting_excluded_users e where e.user_id=u.id) as excluded_from_reports
from public.app_users u join public.org_people p on p.auth_user_id=u.id
join auth.users a on a.id=u.id
where u.id='4ccab1c6-34b7-4076-bfc3-19320fdc5207' and u.login_id='6392304061';
