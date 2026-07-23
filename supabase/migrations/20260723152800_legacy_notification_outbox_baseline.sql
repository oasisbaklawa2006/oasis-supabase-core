-- Point 25 clean-replay repair: the notification tables existed in production
-- before Core migration ownership. This additive baseline represents their
-- legacy shape so subsequent Point 21 governance migrations replay from zero.

create table if not exists public.notification_events (
  id uuid primary key default gen_random_uuid(),
  event_key text not null unique,
  event_name text not null,
  is_enabled boolean default true,
  priority text default 'normal',
  channels text[] default array['email']::text[],
  template_body text not null,
  created_at timestamptz default now()
);

create table if not exists public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  recipient_phone text,
  recipient_email text,
  message_body text not null,
  priority text default 'normal',
  status text default 'pending',
  error_log text,
  event_type text,
  created_at timestamptz default now(),
  sent_at timestamptz,
  constraint notification_outbox_status_check
    check (status in ('pending','sent','failed'))
);

alter table public.notification_events enable row level security;
alter table public.notification_outbox enable row level security;

comment on table public.notification_outbox is
  'Legacy notification queue baseline represented for deterministic Core migration replay.';
comment on table public.notification_events is
  'Legacy notification template/event baseline represented for deterministic Core migration replay.';
