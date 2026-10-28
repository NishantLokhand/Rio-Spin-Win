-- Supabase safe-update protection requires an explicit conflict-update WHERE.
-- This fixes post-spin activity flag upserts without changing flag behavior.
create or replace function public._flag(
  p_promoter uuid,
  p_campaign uuid,
  p_type text,
  p_severity text,
  p_reason text,
  p_details jsonb default '{}'::jsonb
)
returns void language plpgsql security definer set search_path=public as $$
declare
  v_key text := coalesce(p_promoter::text,'-') || ':' || p_type || ':' || public.ist_today()::text;
begin
  insert into public.activity_flags(promoter_id, campaign_id, flag_type, severity, reason, details, flag_date, flag_key)
  values (p_promoter, p_campaign, p_type, p_severity, p_reason, coalesce(p_details,'{}'::jsonb), public.ist_today(), v_key)
  on conflict (flag_key) do update
     set occurrences = public.activity_flags.occurrences + 1,
         reason      = excluded.reason,
         details     = excluded.details,
         status      = case when public.activity_flags.status = 'dismissed' then 'dismissed'::public.flag_status else 'open'::public.flag_status end,
         updated_at  = now()
   where public.activity_flags.flag_key = excluded.flag_key;
end $$;

notify pgrst, 'reload schema';
