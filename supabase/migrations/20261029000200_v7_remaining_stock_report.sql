-- Reporting-only change: include remaining speakers in the Version 7 report.
-- Does not alter any draw function, percentage, eligibility, or inventory balance.
begin;
create or replace function public.report_v7_expiry_users()returns jsonb language plpgsql stable security definer set search_path=public as $report$
declare v_result jsonb;
begin
  perform public._require_staff();
  select coalesce(jsonb_agg(to_jsonb(r) order by r.full_name),'[]'::jsonb) into v_result
  from (
    select o.user_id,u.full_name,u.login_id,o.mode,
      public._v7_distribution_mode(o.user_id) is not null as enabled,
      case when o.mode='no_snack5' then
        case when coalesce(st.shades,0)>0 then '96% ₹10 / 4% shades' else '100% ₹10 (shades empty)' end
        when coalesce(st.shades,0)>0 then '90% ₹10 / 6% ₹5 / 4% shades'
        else '95% ₹10 / 5% ₹5' end as effective_rule,
      o.starts_on,o.expires_on,
      coalesce((select op.state_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as state,
      coalesce((select op.market_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as city,
      coalesce((select op.area_raw from public.org_people op where op.auth_user_id=u.id limit 1),'') as area,
      st.stock,coalesce((st.stock->>'SPEAKER')::integer,0) as speakers_remaining,
      coalesce(sp.spins,0) as spins,coalesce(sp.giveaway_cost,0) as giveaway_cost,
      coalesce(sp.snack5_used,0) as snack5_used,coalesce(sp.snack10_used,0) as snack10_used,
      coalesce(sp.shades_used,0) as shades_used
    from public.prize_user_distribution_overrides o join public.app_users u on u.id=o.user_id
    left join lateral (
      select jsonb_object_agg(p.code,pi.on_hand-pi.reserved) as stock,
        max(pi.on_hand-pi.reserved) filter(where p.code='SHADES') as shades
      from public.promoter_inventory pi join public.prizes p on p.id=pi.prize_id
      where pi.promoter_id=u.id and p.code in ('SNACK5','SNACK10','SHADES','SPEAKER')
    ) st on true
    left join lateral (
      select count(*) as spins,coalesce(sum(s.prize_cost),0) as giveaway_cost,
        count(*) filter(where s.prize_code='SNACK5') as snack5_used,
        count(*) filter(where s.prize_code='SNACK10') as snack10_used,
        count(*) filter(where s.prize_code='SHADES') as shades_used
      from public.spins s where s.promoter_id=u.id and s.distribution_version=7
        and s.biz_date between o.starts_on and o.expires_on and s.redemption_status<>'not_redeemed'
    ) sp on true
    where o.version=7 and o.expires_on>=date '2026-10-29'
  ) r;
  return v_result;
end $report$;
revoke all on function public.report_v7_expiry_users() from public,anon,authenticated;
grant execute on function public.report_v7_expiry_users() to authenticated;
notify pgrst,'reload schema';
commit;
