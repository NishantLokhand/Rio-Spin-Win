alter table public.app_users
  add column if not exists whatsapp_alerts_enabled boolean not null default false,
  add column if not exists whatsapp_opted_out_at timestamptz;

create table if not exists public.whatsapp_reminder_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.app_users(id) on delete cascade,
  reminder_date date not null,
  reminder_stage text not null check (reminder_stage in ('7pm','8pm','9pm')),
  threshold int not null check (threshold > 0),
  spin_count_at_send int not null default 0,
  provider_message_id text,
  status text not null default 'submitted',
  failure_reason text,
  sent_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, reminder_date, reminder_stage)
);

create index if not exists whatsapp_reminder_log_date_idx
  on public.whatsapp_reminder_log(reminder_date, reminder_stage, status);

alter table public.whatsapp_reminder_log enable row level security;
