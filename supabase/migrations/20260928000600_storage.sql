-- =====================================================================
-- RIO SPIN & WIN — 006 STORAGE (prize images) — Supabase only
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('prize-images', 'prize-images', true)
on conflict (id) do nothing;

create policy "prize images readable by all"
  on storage.objects for select
  using (bucket_id = 'prize-images');

create policy "admins upload prize images"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'prize-images' and public.is_admin());

create policy "admins update prize images"
  on storage.objects for update to authenticated
  using (bucket_id = 'prize-images' and public.is_admin());

create policy "admins delete prize images"
  on storage.objects for delete to authenticated
  using (bucket_id = 'prize-images' and public.is_admin());
