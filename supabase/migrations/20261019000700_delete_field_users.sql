-- Logical deletion preserves immutable sales, spins and stock ledger references.
create table if not exists public.deleted_field_users (
  user_id uuid primary key references public.app_users(id),
  deleted_by uuid not null references public.app_users(id),
  deleted_at timestamptz not null default now()
);
alter table public.deleted_field_users enable row level security;
revoke all on public.deleted_field_users from public,anon,authenticated;

create or replace function public.get_deleted_field_users() returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform public._require_admin();
  return (select coalesce(jsonb_agg(user_id),'[]'::jsonb) from public.deleted_field_users);
end $$;

create or replace function public.delete_field_user(p_user_id uuid,p_confirm_login text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare actor public.app_users; target public.app_users;
begin
  actor:=public._require_admin();
  if p_user_id=actor.id then raise exception 'You cannot delete yourself.'; end if;
  select * into target from public.app_users where id=p_user_id for update;
  if target.id is null then raise exception 'User not found.'; end if;
  if target.role<>'promoter' then raise exception 'Only field users can be deleted here.'; end if;
  if p_confirm_login is distinct from target.login_id then raise exception 'Enter the exact login ID to confirm deletion.'; end if;
  if exists(select 1 from public.deleted_field_users where user_id=p_user_id) then return jsonb_build_object('ok',true); end if;
  update public.app_users set is_active=false where id=p_user_id;
  update public.org_people set active=false where auth_user_id=p_user_id;
  insert into public.deleted_field_users(user_id,deleted_by) values(p_user_id,actor.id);
  insert into public.reporting_excluded_users(user_id,reason) values(p_user_id,'Deleted field user')
    on conflict(user_id) do nothing;
  perform public.write_audit('FIELD_USER_DELETED','app_users',p_user_id::text,
    jsonb_build_object('full_name',target.full_name,'login_id',target.login_id,'history_preserved',true));
  return jsonb_build_object('ok',true);
end $$;

create or replace function public._prevent_deleted_user_enable() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.is_active and exists(select 1 from public.deleted_field_users where user_id=new.id) then
    raise exception 'Deleted users cannot be enabled.';
  end if;
  return new;
end $$;
drop trigger if exists prevent_deleted_user_enable on public.app_users;
create trigger prevent_deleted_user_enable before update of is_active on public.app_users
  for each row execute function public._prevent_deleted_user_enable();
revoke all on function public._prevent_deleted_user_enable() from public,anon,authenticated;
revoke all on function public.get_deleted_field_users(),public.delete_field_user(uuid,text) from public,anon;
grant execute on function public.get_deleted_field_users(),public.delete_field_user(uuid,text) to authenticated;
notify pgrst,'reload schema';
