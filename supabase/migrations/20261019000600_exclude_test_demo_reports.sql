-- Reporting-only exclusions: retain accounts, raw activity and physical stock history.
create table if not exists public.reporting_excluded_users (
  user_id uuid primary key references public.app_users(id),
  reason text not null default 'Test/demo account'
);
alter table public.reporting_excluded_users enable row level security;
revoke all on public.reporting_excluded_users from public,anon,authenticated;

-- Persist current identities so renaming a test login cannot reintroduce its history.
insert into public.reporting_excluded_users(user_id)
select id from public.app_users where role='promoter'
  and (full_name ~* '(^|[^[:alnum:]])(test|demo)([^[:alnum:]]|$)'
    or login_id ~* '^(test|demo)([^[:alpha:]]|$)')
on conflict(user_id) do nothing;

create or replace function public._report_excluded_user_ids() returns uuid[]
language sql stable security definer set search_path=public as $$
  select coalesce(array_agg(distinct a.id),'{}'::uuid[]) from public.app_users a
  where exists(select 1 from public.reporting_excluded_users e where e.user_id=a.id)
    or (a.role='promoter' and (a.full_name ~* '(^|[^[:alnum:]])(test|demo)([^[:alnum:]]|$)'
      or a.login_id ~* '^(test|demo)([^[:alpha:]]|$)'))
$$;
revoke all on function public._report_excluded_user_ids() from public,anon,authenticated;

create or replace function public.get_reporting_excluded_users() returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  perform public._require_staff();
  return to_jsonb(public._report_excluded_user_ids());
end $$;
revoke all on function public.get_reporting_excluded_users() from public,anon;
grant execute on function public.get_reporting_excluded_users() to authenticated;

-- Extend the shared predicate without changing any existing scope/date/product filters.
do $$
declare predicate text;
begin
  predicate:=public._sales_where();
  if position('_report_excluded_user_ids' in predicate)=0 then
    predicate:='('||predicate||') and not (s.promoter_id = any((select public._report_excluded_user_ids())::uuid[]))';
    execute format('create or replace function public._sales_where() returns text language sql immutable as %L',
      'select '||quote_literal(predicate));
  end if;
end $$;
notify pgrst,'reload schema';
