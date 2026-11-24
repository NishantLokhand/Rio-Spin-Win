-- Stop future scheduled emails only. Keep report, delivery history and all app data.
begin;
do $$ declare job bigint;begin
  if to_regclass('cron.job') is not null then
    for job in select jobid from cron.job where jobname='rio-daily-low-spin-email' loop
      perform cron.unschedule(job);
    end loop;
  end if;
end $$;
commit;
