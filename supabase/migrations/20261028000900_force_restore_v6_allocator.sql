-- Force-remove any remaining temporary Version 7 lines from the shared
-- allocator. This is intentionally a safety migration for live spinning.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='_draw_cumulative_prize' and p.pronargs=4
   order by p.oid desc limit 1;
  if d is null then raise exception 'Current cumulative prize allocator is missing'; end if;
  d := regexp_replace(d, E'\\n[[:space:]]*and[[:space:]]+\\(not p_campaign\\.snack_launch_active[^\\n]*_v7_distribution_mode[^\\n]*', E'\n       and (not p_campaign.snack_launch_active or pz.code in (''SNACK5'',''SNACK10''))', 'g');
  d := regexp_replace(d, E'\\n[^\\n]*_v7_distribution_mode[^\\n]*', '', 'g');
  execute d;
end $$;
notify pgrst, 'reload schema';
