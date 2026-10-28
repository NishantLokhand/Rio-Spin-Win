-- Prize counts by user for the selected reporting period.
create or replace function public.report_user_prize_breakdown(
  p_date_from date default null,
  p_date_to date default null
) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare
  u public.app_users;
  result jsonb;
begin
  u := public._require_staff();
  select coalesce(jsonb_agg(row_to_json(r)), '[]'::jsonb) into result
    from (
      select s.promoter_id as user_id,
        count(*) filter (where s.prize_code = 'SNACK5') as snack5,
        count(*) filter (where s.prize_code = 'SNACK10') as snack10,
        count(*) filter (where s.prize_code = 'SHADES') as shades,
        count(*) filter (where s.prize_code not in ('SNACK5','SNACK10','SHADES')) as other
      from public.spins s
      where (p_date_from is null or s.biz_date >= p_date_from)
        and (p_date_to is null or s.biz_date <= p_date_to)
        and (u.role = 'admin' or s.promoter_id in (
          select pr.user_id from public.promoters pr where pr.supervisor_id = u.id
        ))
        and not (s.promoter_id = any((select public._report_excluded_user_ids())::uuid[]))
      group by s.promoter_id
    ) r;
  return result;
end $$;

revoke all on function public.report_user_prize_breakdown(date,date) from public, anon;
grant execute on function public.report_user_prize_breakdown(date,date) to authenticated;
notify pgrst, 'reload schema';
