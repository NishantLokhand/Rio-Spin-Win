-- Report helpers expose deactivation dates without exposing the protected
-- deletion table. Clients use the date as a reporting cutoff only.
create or replace function public.get_deleted_field_user_cutoffs()
returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform public._require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object('user_id', user_id, 'deleted_at', deleted_at))
      from public.deleted_field_users
  ), '[]'::jsonb);
end $$;

revoke all on function public.get_deleted_field_user_cutoffs() from public, anon;
grant execute on function public.get_deleted_field_user_cutoffs() to authenticated;
notify pgrst, 'reload schema';
