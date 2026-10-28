-- Corrected deactivation for the seven verified accounts.
-- Uses the verified user IDs because two requested cities are stored in area data.
do $$
declare
  admin_id uuid;
  target record;
begin
  select id into admin_id
    from public.app_users
   where role = 'admin' and is_active
   order by created_at
   limit 1;
  if admin_id is null then
    raise exception 'No active admin account is available to record this deactivation';
  end if;

  for target in
    select id, full_name, login_id
      from public.app_users
     where id in (
       '912f9b5d-4949-437a-be67-f383104fb5a8',
       '08d94033-a724-44c4-b351-65cee40e24cd',
       '7c5b82d2-36dd-45a7-85f0-5adbcd3454a7',
       '1cf5df2e-0394-49f4-918f-73c11a4f1bde',
       '5b1616be-3371-4db7-9820-7fc4ce6c7dd7',
       '4ccab1c6-34b7-4076-bfc3-19320fdc5207',
       '556896c6-0795-4983-ae29-8c55a8e274cf'
     )
       and role = 'promoter'
     order by full_name
  loop
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
        'history_preserved', true,
        'deactivation_only', true
      )
    );
  end loop;

  notify pgrst, 'reload schema';
end $$;
