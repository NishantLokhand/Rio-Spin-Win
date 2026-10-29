-- Immediate rollback: subsequent draws use the preserved Version 6 function.
-- Existing spins, awards, inventory, and historical reports are retained.
begin;
set local lock_timeout = '5s';
update public.prize_v7_settings s
   set enabled=false,updated_at=now()
 where s.campaign_id in (select c.id from public.campaigns c where c.code='RSW-2026');
notify pgrst,'reload schema';
commit;
