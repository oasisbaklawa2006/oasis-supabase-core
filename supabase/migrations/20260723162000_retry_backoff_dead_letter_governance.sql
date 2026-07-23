-- Point 24: shared retry, backoff and dead-letter governance

create table if not exists public.retry_policies (
  id uuid primary key default gen_random_uuid(),
  policy_key text not null unique,
  owning_application text not null,
  workload_type text not null,
  max_attempts integer not null default 5,
  base_delay_seconds integer not null default 60,
  max_delay_seconds integer not null default 3600,
  backoff_multiplier numeric(8,3) not null default 2.000,
  jitter_percent integer not null default 10,
  dead_letter_enabled boolean not null default true,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint retry_policies_key_nonempty check (btrim(policy_key) <> ''),
  constraint retry_policies_owner_nonempty check (btrim(owning_application) <> ''),
  constraint retry_policies_workload_nonempty check (btrim(workload_type) <> ''),
  constraint retry_policies_attempts_check check (max_attempts between 1 and 50),
  constraint retry_policies_delay_check check (
    base_delay_seconds >= 0
    and max_delay_seconds >= base_delay_seconds
    and max_delay_seconds <= 604800
  ),
  constraint retry_policies_multiplier_check check (backoff_multiplier >= 1 and backoff_multiplier <= 10),
  constraint retry_policies_jitter_check check (jitter_percent between 0 and 100)
);

create table if not exists public.dead_letter_entries (
  id uuid primary key default gen_random_uuid(),
  source_application text not null,
  workload_type text not null,
  source_table text not null,
  source_record_id text not null,
  policy_key text references public.retry_policies(policy_key),
  idempotency_key text,
  attempt_count integer not null,
  error_code text,
  error_message text not null,
  context jsonb not null default '{}'::jsonb,
  status text not null default 'open',
  first_failed_at timestamptz not null default now(),
  last_failed_at timestamptz not null default now(),
  requeued_at timestamptz,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint dead_letter_source_nonempty check (
    btrim(source_application) <> '' and btrim(workload_type) <> ''
    and btrim(source_table) <> '' and btrim(source_record_id) <> ''
  ),
  constraint dead_letter_attempt_count_check check (attempt_count >= 1),
  constraint dead_letter_error_nonempty check (btrim(error_message) <> ''),
  constraint dead_letter_status_check check (status in ('open','requeued','resolved','discarded'))
);

create unique index if not exists dead_letter_open_source_uidx
  on public.dead_letter_entries (source_table, source_record_id)
  where status = 'open';

create index if not exists dead_letter_status_created_idx
  on public.dead_letter_entries (status, created_at desc);

create index if not exists dead_letter_application_workload_idx
  on public.dead_letter_entries (source_application, workload_type, created_at desc);

insert into public.retry_policies (
  policy_key, owning_application, workload_type, max_attempts,
  base_delay_seconds, max_delay_seconds, backoff_multiplier,
  jitter_percent, dead_letter_enabled, is_active
) values
  ('notification.delivery.default', 'Supabase Core', 'notification_delivery', 5, 60, 3600, 2.000, 10, true, true),
  ('whatsapp.delivery.default', 'Central', 'whatsapp_delivery', 5, 30, 1800, 2.000, 15, true, true)
on conflict (policy_key) do update set
  owning_application = excluded.owning_application,
  workload_type = excluded.workload_type,
  max_attempts = excluded.max_attempts,
  base_delay_seconds = excluded.base_delay_seconds,
  max_delay_seconds = excluded.max_delay_seconds,
  backoff_multiplier = excluded.backoff_multiplier,
  jitter_percent = excluded.jitter_percent,
  dead_letter_enabled = excluded.dead_letter_enabled,
  is_active = excluded.is_active,
  updated_at = now();

create or replace function public.calculate_retry_delay_v1(
  p_policy_key text,
  p_attempt_count integer,
  p_jitter_seed text default null
)
returns integer
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
declare
  v_policy public.retry_policies%rowtype;
  v_raw numeric;
  v_jitter_span numeric;
  v_jitter numeric := 0;
begin
  if p_attempt_count < 1 then
    raise exception 'attempt_count must be positive';
  end if;

  select * into v_policy
  from public.retry_policies
  where policy_key = p_policy_key and is_active;

  if not found then
    raise exception 'active retry policy not found: %', p_policy_key;
  end if;

  v_raw := least(
    v_policy.max_delay_seconds::numeric,
    v_policy.base_delay_seconds::numeric * power(v_policy.backoff_multiplier, p_attempt_count - 1)
  );

  if v_policy.jitter_percent > 0 and p_jitter_seed is not null then
    v_jitter_span := v_raw * v_policy.jitter_percent / 100.0;
    v_jitter := ((abs(hashtext(p_jitter_seed || ':' || p_attempt_count::text)) % 2001)::numeric / 1000.0 - 1.0) * v_jitter_span;
  end if;

  return greatest(0, least(v_policy.max_delay_seconds, round(v_raw + v_jitter)::integer));
end;
$$;

create or replace function public.record_dead_letter_v1(
  p_source_application text,
  p_workload_type text,
  p_source_table text,
  p_source_record_id text,
  p_policy_key text,
  p_attempt_count integer,
  p_error_message text,
  p_error_code text default null,
  p_idempotency_key text default null,
  p_context jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;

  if nullif(btrim(p_source_application), '') is null
     or nullif(btrim(p_workload_type), '') is null
     or nullif(btrim(p_source_table), '') is null
     or nullif(btrim(p_source_record_id), '') is null
     or nullif(btrim(p_error_message), '') is null then
    raise exception 'source, workload, table, record and error message are required';
  end if;

  insert into public.dead_letter_entries (
    source_application, workload_type, source_table, source_record_id,
    policy_key, idempotency_key, attempt_count, error_code,
    error_message, context, first_failed_at, last_failed_at, updated_at
  ) values (
    p_source_application, p_workload_type, p_source_table, p_source_record_id,
    p_policy_key, p_idempotency_key, p_attempt_count, p_error_code,
    left(p_error_message, 4000), coalesce(p_context, '{}'::jsonb), now(), now(), now()
  )
  on conflict (source_table, source_record_id) where status = 'open'
  do update set
    attempt_count = greatest(public.dead_letter_entries.attempt_count, excluded.attempt_count),
    error_code = excluded.error_code,
    error_message = excluded.error_message,
    context = excluded.context,
    last_failed_at = now(),
    updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.resolve_dead_letter_v1(
  p_dead_letter_id uuid,
  p_status text,
  p_resolution_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.role() <> 'service_role' then
    if auth.uid() is null or public.get_user_role(auth.uid()) not in ('admin','super_admin') then
      raise exception 'administrator or service role required';
    end if;
  end if;

  if p_status not in ('requeued','resolved','discarded') then
    raise exception 'invalid terminal dead-letter status';
  end if;

  update public.dead_letter_entries
  set status = p_status,
      requeued_at = case when p_status = 'requeued' then now() else requeued_at end,
      resolved_at = case when p_status in ('resolved','discarded') then now() else resolved_at end,
      resolved_by = auth.uid(),
      resolution_note = p_resolution_note,
      updated_at = now()
  where id = p_dead_letter_id and status = 'open';

  if not found then
    raise exception 'open dead-letter entry not found';
  end if;
end;
$$;

-- Upgrade the notification failure transition to shared policy-based backoff
-- and automatic dead-letter capture on the final attempt.
create or replace function public.fail_notification_v1(
  p_notification_id uuid,
  p_worker_id text,
  p_error text,
  p_retry_delay_seconds integer default null
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.notification_outbox%rowtype;
  v_status text;
  v_delay integer;
  v_dead_letter_enabled boolean;
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;

  select * into v_row
  from public.notification_outbox
  where id = p_notification_id
    and status = 'processing'
    and locked_by = p_worker_id
  for update;

  if not found then
    raise exception 'notification lease not owned';
  end if;

  select dead_letter_enabled into v_dead_letter_enabled
  from public.retry_policies
  where policy_key = 'notification.delivery.default' and is_active;

  if v_row.attempt_count >= v_row.max_attempts then
    v_status := 'failed';
  else
    v_status := 'retry';
    v_delay := coalesce(
      p_retry_delay_seconds,
      public.calculate_retry_delay_v1(
        'notification.delivery.default',
        v_row.attempt_count,
        coalesce(v_row.idempotency_key, v_row.id::text)
      )
    );
  end if;

  update public.notification_outbox
  set status = v_status,
      next_attempt_at = case when v_status = 'retry' then now() + make_interval(secs => greatest(v_delay, 0)) else next_attempt_at end,
      error_log = left(coalesce(p_error, 'unknown delivery error'), 4000),
      locked_at = null,
      locked_by = null,
      updated_at = now()
  where id = p_notification_id;

  if v_status = 'failed' and coalesce(v_dead_letter_enabled, true) then
    perform public.record_dead_letter_v1(
      v_row.source_application,
      'notification_delivery',
      'notification_outbox',
      v_row.id::text,
      'notification.delivery.default',
      v_row.attempt_count,
      coalesce(p_error, 'unknown delivery error'),
      null,
      v_row.idempotency_key,
      jsonb_build_object(
        'event_type', v_row.event_type,
        'channel', v_row.channel,
        'priority', v_row.priority,
        'provider_message_id', v_row.provider_message_id
      )
    );
  end if;

  return v_status;
end;
$$;

alter table public.retry_policies enable row level security;
alter table public.dead_letter_entries enable row level security;

drop policy if exists "Staff read retry policies" on public.retry_policies;
create policy "Staff read retry policies"
on public.retry_policies for select to authenticated
using (public.is_internal_staff(auth.uid()));

drop policy if exists "Admins manage retry policies" on public.retry_policies;
create policy "Admins manage retry policies"
on public.retry_policies for all to authenticated
using (public.get_user_role(auth.uid()) in ('admin','super_admin'))
with check (public.get_user_role(auth.uid()) in ('admin','super_admin'));

drop policy if exists "Staff read dead letters" on public.dead_letter_entries;
create policy "Staff read dead letters"
on public.dead_letter_entries for select to authenticated
using (public.is_internal_staff(auth.uid()));

drop policy if exists "Admins manage dead letters" on public.dead_letter_entries;
create policy "Admins manage dead letters"
on public.dead_letter_entries for all to authenticated
using (public.get_user_role(auth.uid()) in ('admin','super_admin'))
with check (public.get_user_role(auth.uid()) in ('admin','super_admin'));

revoke all on function public.calculate_retry_delay_v1(text,integer,text) from public, anon;
grant execute on function public.calculate_retry_delay_v1(text,integer,text) to authenticated, service_role;

revoke all on function public.record_dead_letter_v1(text,text,text,text,text,integer,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.record_dead_letter_v1(text,text,text,text,text,integer,text,text,text,jsonb) to service_role;

revoke all on function public.resolve_dead_letter_v1(uuid,text,text) from public, anon;
grant execute on function public.resolve_dead_letter_v1(uuid,text,text) to authenticated, service_role;

revoke all on function public.fail_notification_v1(uuid,text,text,integer) from public, anon, authenticated;
grant execute on function public.fail_notification_v1(uuid,text,text,integer) to service_role;
