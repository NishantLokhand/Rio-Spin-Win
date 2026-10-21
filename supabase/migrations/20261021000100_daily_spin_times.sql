-- Actual server spin timestamps, grouped by the same business date as user reports.
create or replace function public.get_user_daily_spin_times()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare actor public.app_users; result jsonb;
begin
  actor:=public._require_staff();
  select coalesce(jsonb_agg(r order by r.date desc,r.key),'[]'::jsonb) into result from (
    select sp.promoter_id as key,sp.biz_date as date,min(sp.created_at) as first_spin_at,
      max(sp.created_at) as last_spin_at,
      extract(epoch from max(sp.created_at)-min(sp.created_at)) as activity_span_seconds
    from public.spins sp join public.promoters p on p.user_id=sp.promoter_id
    where (actor.role='admin' or p.supervisor_id=actor.id)
      and not (sp.promoter_id=any((select public._report_excluded_user_ids())::uuid[]))
    group by sp.promoter_id,sp.biz_date
  ) r;
  return result;
end $$;
revoke all on function public.get_user_daily_spin_times() from public,anon;
grant execute on function public.get_user_daily_spin_times() to authenticated;
notify pgrst,'reload schema';
