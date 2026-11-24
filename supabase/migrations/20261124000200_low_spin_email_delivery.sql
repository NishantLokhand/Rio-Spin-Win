-- Isolated email delivery bookkeeping. No changes to sales, spins, prizes or stock.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
create table if not exists public.low_spin_email_deliveries (
  report_date date not null,
  kind text not null check(kind in ('scheduled','test')),
  status text not null default 'processing' check(status in ('processing','dispatching','uncertain','sent','failed')),
  lease_token uuid not null default gen_random_uuid(),
  lease_until timestamptz not null default now()+interval '5 minutes',
  attempts integer not null default 1,
  payload jsonb,
  provider_id text,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  primary key(report_date,kind)
);
alter table public.low_spin_email_deliveries enable row level security;
revoke all on public.low_spin_email_deliveries from public,anon,authenticated;
grant select,insert,update on public.low_spin_email_deliveries to service_role;

create or replace function public.claim_low_spin_email(p_date date,p_kind text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare delivery public.low_spin_email_deliveries; token uuid:=gen_random_uuid();
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Service access required';end if;
  if p_date is null or p_date>=public.ist_today() or p_kind not in ('test','scheduled') or p_kind is null then
    raise exception 'Choose a completed India business date and valid delivery kind';
  end if;
  insert into public.low_spin_email_deliveries(report_date,kind,lease_token)
  values(p_date,p_kind,token) on conflict(report_date,kind) do nothing;
  select * into delivery from public.low_spin_email_deliveries where report_date=p_date and kind=p_kind for update;
  if delivery.lease_token<>token then
    -- Never replay an ambiguous provider request after its 24-hour idempotency window.
    if delivery.status in ('sent','dispatching','uncertain') or delivery.lease_until>now() or delivery.attempts>=3 or delivery.created_at<now()-interval '20 hours' then
      return jsonb_build_object('claimed',false,'status',delivery.status);
    end if;
    update public.low_spin_email_deliveries set lease_token=token,lease_until=now()+interval '5 minutes',
      attempts=attempts+1,status='processing' where report_date=p_date and kind=p_kind;
  end if;
  return jsonb_build_object('claimed',true,'token',token,'payload',delivery.payload);
end $$;
create or replace function public.begin_low_spin_email_send(p_date date,p_kind text,p_token uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Service access required';end if;
  -- Gmail has no send idempotency key. Once dispatch starts, an ambiguous failure
  -- requires review rather than an automatic retry that might duplicate a mail.
  update public.low_spin_email_deliveries set status='dispatching'
    where report_date=p_date and kind=p_kind and lease_token=p_token
      and status='processing' and lease_until>now() and payload is not null;
  return found;
end $$;
create or replace function public.prepare_low_spin_email(p_date date,p_kind text,p_token uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Service access required';end if;
  if jsonb_typeof(p_payload)<>'object' or p_payload is null then raise exception 'Email payload required';end if;
  update public.low_spin_email_deliveries set payload=coalesce(payload,p_payload)
    where report_date=p_date and kind=p_kind and lease_token=p_token and status='processing' and lease_until>now()
    returning payload into result;
  if result is null then raise exception 'Email lease expired';end if;
  return result;
end $$;
create or replace function public.finish_low_spin_email(p_date date,p_kind text,p_token uuid,p_provider_id text,p_error text default null)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Service access required';end if;
  if p_provider_id is null and p_error is null then raise exception 'Provider result required';end if;
  update public.low_spin_email_deliveries set
    status=case when p_provider_id is not null then 'sent' when status='dispatching' then 'uncertain' else 'failed' end,
    provider_id=p_provider_id,last_error=left(p_error,300),
    sent_at=case when p_provider_id is not null then now() end,lease_until=now()
    where report_date=p_date and kind=p_kind and lease_token=p_token and status in ('processing','dispatching');
  return found;
end $$;
revoke all on function public.claim_low_spin_email(date,text),public.prepare_low_spin_email(date,text,uuid,jsonb),public.begin_low_spin_email_send(date,text,uuid),public.finish_low_spin_email(date,text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.claim_low_spin_email(date,text),public.prepare_low_spin_email(date,text,uuid,jsonb),public.begin_low_spin_email_send(date,text,uuid),public.finish_low_spin_email(date,text,uuid,text,text) to service_role;
notify pgrst,'reload schema';
commit;
