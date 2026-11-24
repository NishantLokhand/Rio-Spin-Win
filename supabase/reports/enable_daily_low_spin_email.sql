-- Run ONLY after deploying send-low-spin-report and a successful real test delivery.
-- Vault must contain low_spin_report_url and low_spin_report_token. The latter
-- must match the Edge secret LOW_SPIN_CRON_TOKEN. Never put secrets in Git.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
do $$ begin
  if not exists(select 1 from vault.decrypted_secrets where name='low_spin_report_url'
    and decrypted_secret ~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/send-low-spin-report$')
    or not exists(select 1 from vault.decrypted_secrets where name='low_spin_report_token' and length(decrypted_secret)>=32) then
    raise exception 'Configure the report URL and matching private cron token in Vault first';
  end if;
  if not exists(select 1 from public.low_spin_email_deliveries where kind='test' and status='sent') then
    raise exception 'A successful test email is required before enabling the daily job';
  end if;
end $$;
-- pg_cron is UTC: 04:30 = 10:00 India time. Later runs are guarded retries only.
select cron.schedule('rio-daily-low-spin-email','30,40,50 4 * * *',$job$
  select net.http_post(
    url:=(select decrypted_secret from vault.decrypted_secrets where name='low_spin_report_url'),
    headers:=jsonb_build_object('Content-Type','application/json','x-report-token',
      (select decrypted_secret from vault.decrypted_secrets where name='low_spin_report_token')),
    body:='{"mode":"scheduled"}'::jsonb,timeout_milliseconds:=60000
  );
$job$);
commit;
