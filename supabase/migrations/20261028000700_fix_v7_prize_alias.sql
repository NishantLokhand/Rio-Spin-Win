-- Corrective patch for Version 7: make override prize-code predicates
-- independent of the deployed allocator's local prize alias.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p
   join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='_draw_cumulative_prize' and p.pronargs=4
   order by p.oid desc limit 1;
  if d is null then raise exception 'Current cumulative prize allocator is missing'; end if;
  d := replace(d, 'p_campaign.snack_launch_active and public._v7_distribution_mode(p_promoter) is null', 'p_campaign.snack_launch_active and public._v7_distribution_mode(p_promoter) is null');
  d := replace(d, 'public._v7_distribution_mode(p_promoter) = ''no_snack5'' and pz.code', 'public._v7_distribution_mode(p_promoter) = ''no_snack5'' and (select code from public.prizes where id=i.prize_id)');
  d := replace(d, 'public._v7_distribution_mode(p_promoter) = ''shades'' and pz.code', 'public._v7_distribution_mode(p_promoter) = ''shades'' and (select code from public.prizes where id=i.prize_id)');
  d := replace(d, 'public._v7_distribution_mode(p_promoter) = ''snacks'' and pz.code', 'public._v7_distribution_mode(p_promoter) = ''snacks'' and (select code from public.prizes where id=i.prize_id)');
  execute d;
end $$;
notify pgrst, 'reload schema';
