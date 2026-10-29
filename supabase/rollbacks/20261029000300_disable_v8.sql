-- Normal rollback: subsequent spins follow the current V7/V6 rules.
-- Daily claims are preserved, so re-enabling cannot grant another speaker.
begin;
set local lock_timeout='5s';
update public.prize_v8_settings s set enabled=false,updated_at=now()
where s.campaign_id in (select id from public.campaigns where code='RSW-2026');
notify pgrst,'reload schema';
commit;
