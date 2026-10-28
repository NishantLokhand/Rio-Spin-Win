-- Safety rollback for the shared allocator. This removes only the temporary
-- Version 7 SQL branch from the executable allocator; user override records
-- and the Version 7 tracking report remain preserved.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='_draw_cumulative_prize' and p.pronargs=4
   order by p.oid desc limit 1;
  if d is null then raise exception 'Current cumulative prize allocator is missing'; end if;
  d := regexp_replace(d,
    'when public[.]_v7_distribution_mode\\(p_promoter\\) = ''no_snack5''.*?when v_special_campaign and v_shade_eligible then',
    'when v_special_campaign and v_shade_eligible then', 'n');
  d := replace(d,
    'and (not p_campaign.snack_launch_active or pz.code in (''SNACK5'',''SNACK10'') or public._v7_distribution_mode(p_promoter) in (''shades'',''no_snack5''))',
    'and (not p_campaign.snack_launch_active or pz.code in (''SNACK5'',''SNACK10''))');
  d := replace(d, 'public._v7_distribution_mode(p_promoter) is null and ', '');
  execute d;
end $$;
notify pgrst, 'reload schema';
