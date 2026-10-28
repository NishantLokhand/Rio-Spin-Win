-- Repair the allocation UPDATE clause removed by the earlier safety regex.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='_draw_cumulative_prize' and p.pronargs=4
   order by p.oid desc limit 1;
  if d is null then raise exception 'Current cumulative prize allocator is missing'; end if;
  d := replace(d,
    E'to_jsonb(coalesce((awarded->>v_won_prize::text)::int, 0) + 1)),\n               when v_special_campaign',
    E'to_jsonb(coalesce((awarded->>v_won_prize::text)::int, 0) + 1)),\n         shade_eligible_spins = shade_eligible_spins + case when v_special_campaign and v_shade_eligible then 1 else 0 end,\n               when v_special_campaign');
  execute d;
end $$;
notify pgrst, 'reload schema';
