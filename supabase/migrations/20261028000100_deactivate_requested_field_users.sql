-- Safely deactivate the requested field users while preserving all history.
-- Matching uses exact normalized names, plus organizational market/city where supplied.
do $$
declare
  admin_id uuid;
  target record;
  matched int;
begin
  select id into admin_id
    from public.app_users
   where role = 'admin' and is_active
   order by created_at
   limit 1;
  if admin_id is null then
    raise exception 'No active admin account is available to record this deactivation';
  end if;

  create temporary table _requested_users(name text not null, city text) on commit drop;
  insert into _requested_users(name, city) values
    ('SUDHIR SINGH', 'VARANASI'),
    ('AVINASH DUBEY', null),
    ('RITESH TIWARI', null),
    ('ABHISHEK MORADABAD', null),
    ('PANKAJ KUMAR', 'MIRZAPUR'),
    ('AKASH SHARMA', 'KANPUR'),
    ('ASHISH NIGAM', null);

  create temporary table _resolved_users on commit drop as
    select
      r.name as requested_name, r.city as requested_city, a.id, a.login_id, a.full_name
    from _requested_users r
    join public.app_users a
      on lower(regexp_replace(btrim(a.full_name), '\\s+', ' ', 'g')) = lower(regexp_replace(btrim(r.name), '\\s+', ' ', 'g'))
     and a.role = 'promoter'
    left join public.org_people p on p.auth_user_id = a.id
    where r.city is null
       or lower(regexp_replace(btrim(coalesce(p.market_override, p.market_raw, '')), '\\s+', ' ', 'g'))
          = lower(regexp_replace(btrim(r.city), '\\s+', ' ', 'g'))
    ;

  select count(*) into matched from _resolved_users;
  if matched <> 7 then
    raise exception 'Expected 7 exact field-user matches, found %; no users were changed', matched;
  end if;

  for target in select * from _resolved_users loop
    update public.app_users set is_active = false, updated_at = now() where id = target.id;
    update public.org_people set active = false, updated_at = now() where auth_user_id = target.id;

    insert into public.deleted_field_users(user_id, deleted_by)
    values (target.id, admin_id)
    on conflict (user_id) do nothing;

    insert into public.reporting_excluded_users(user_id, reason)
    values (target.id, 'Requested field-user removal')
    on conflict (user_id) do nothing;

    perform public.write_audit_as(
      admin_id,
      'FIELD_USER_DELETED',
      'app_users',
      target.id::text,
      jsonb_build_object(
        'full_name', target.full_name,
        'login_id', target.login_id,
        'requested_name', target.requested_name,
        'requested_city', target.requested_city,
        'history_preserved', true,
        'deactivation_only', true
      )
    );
  end loop;

  notify pgrst, 'reload schema';
end $$;
