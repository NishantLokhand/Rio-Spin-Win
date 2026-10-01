-- Support the supervisor/admin request list filter and newest-first ordering.
create index if not exists outlet_requests_status_created_at_idx
  on public.outlet_requests(status, created_at desc);
