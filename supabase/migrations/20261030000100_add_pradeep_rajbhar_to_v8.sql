-- Add the confirmed existing account to V8. His 10 speakers were already
-- issued by the administrator: this changes eligibility/reference data only.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
do $add_user$
declare v_matches integer; v_user uuid;
begin
  if to_regclass('public.prize_v8_users') is null then
    raise exception 'Install the Version 8 migration before adding this user; no changes committed';
  end if;
  select count(*),min(u.id::text)::uuid into v_matches,v_user
  from public.app_users u
  where regexp_replace(upper(u.full_name),'[^A-Z0-9]','','g')='PRADEEPRAJBHAR'
    and u.role='promoter' and u.is_active
    and exists(select 1 from public.promoters p where p.user_id=u.id);
  if v_matches<>1 then
    raise exception 'Expected one exact active field account for PRADEEP RAJBHAR, found %; no changes committed',v_matches;
  end if;
  insert into public.prize_v8_users as existing(user_id,reported_speakers)
  values(v_user,10)
  on conflict(user_id) do update
     set reported_speakers=excluded.reported_speakers
   where existing.user_id=excluded.user_id;
  raise notice 'PRADEEP RAJBHAR added to V8 with reported quantity 10. Existing stock, daily claims, prize rules and global toggles are unchanged.';
end $add_user$;
commit;
