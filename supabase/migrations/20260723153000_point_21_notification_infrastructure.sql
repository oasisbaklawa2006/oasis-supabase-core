-- Point 21: governed notification infrastructure
-- Extends the existing notification_outbox without triggering delivery.

alter table public.notification_outbox
  add column if not exists source_application text,
  add column if not exists channel text,
  add column if not exists idempotency_key text,
  add column if not exists event_id uuid,
  add column if not exists attempt_count integer,
  add column if not exists max_attempts integer,
  add column if not exists next_attempt_at timestamptz,
  add column if not exists locked_at timestamptz,
  add column if not exists locked_by text,
  add column if not exists provider_message_id text,
  add column if not exists last_attempt_at timestamptz,
  add column if not exists updated_at timestamptz;

update public.notification_outbox
set source_application = coalesce(source_application, 'legacy'),
    channel = coalesce(channel,
      case
        when recipient_email is not null then 'email'
        when recipient_phone is not null then 'whatsapp'
        else 'unknown'
      end),
    attempt_count = coalesce(attempt_count, 0),
    max_attempts = coalesce(max_attempts, 5),
    next_attempt_at = coalesce(next_attempt_at, created_at, now()),
    updated_at = coalesce(updated_at, created_at, now())
where source_application is null
   or channel is null
   or attempt_count is null
   or max_attempts is null
   or next_attempt_at is null
   or updated_at is null;

-- Existing pending rows are months old and must not be delivered without review.
update public.notification_outbox
set status = 'quarantined',
    error_log = coalesce(error_log, 'Legacy pending notification quarantined during Point 21 migration; manual review required before requeue.'),
    updated_at = now()
where status = 'pending'
  and created_at < now() - interval '30 days';

alter table public.notification_outbox
  alter column source_application set default 'unknown',
  alter column source_application set not null,
  alter column channel set not null,
  alter column attempt_count set default 0,
  alter column attempt_count set not null,
  alter column max_attempts set default 5,
  alter column max_attempts set not null,
  alter column next_attempt_at set default now(),
  alter column next_attempt_at set not null,
  alter column updated_at set default now(),
  alter column updated_at set not null;

alter table public.notification_outbox
  drop constraint if exists notification_outbox_channel_check,
  add constraint notification_outbox_channel_check check (channel in ('email','whatsapp','sms','push','unknown')),
  drop constraint if exists notification_outbox_status_check,
  add constraint notification_outbox_status_check check (status in ('pending','processing','sent','retry','failed','quarantined','cancelled')),
  drop constraint if exists notification_outbox_attempts_check,
  add constraint notification_outbox_attempts_check check (attempt_count >= 0 and max_attempts > 0 and attempt_count <= max_attempts),
  drop constraint if exists notification_outbox_recipient_check,
  add constraint notification_outbox_recipient_check check (
    (channel = 'email' and recipient_email is not null)
    or (channel in ('whatsapp','sms') and recipient_phone is not null)
    or channel in ('push','unknown')
  );

create unique index if not exists notification_outbox_source_idempotency_uidx
  on public.notification_outbox (source_application, idempotency_key)
  where idempotency_key is not null;

create index if not exists notification_outbox_claim_idx
  on public.notification_outbox (status, next_attempt_at, priority, created_at)
  where status in ('pending','retry');

create index if not exists notification_outbox_event_idx
  on public.notification_outbox (event_id)
  where event_id is not null;

create or replace function public.enqueue_notification_v1(
  p_source_application text,
  p_event_type text,
  p_channel text,
  p_message_body text,
  p_idempotency_key text,
  p_recipient_email text default null,
  p_recipient_phone text default null,
  p_priority text default 'normal',
  p_event_id uuid default null,
  p_max_attempts integer default 5,
  p_next_attempt_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_existing public.notification_outbox%rowtype;
begin
  if auth.role() <> 'service_role' then
    if auth.uid() is null or not public.is_internal_staff(auth.uid()) then
      raise exception 'internal staff or service role required';
    end if;
  end if;

  if nullif(btrim(p_source_application), '') is null
     or nullif(btrim(p_event_type), '') is null
     or nullif(btrim(p_channel), '') is null
     or nullif(btrim(p_message_body), '') is null
     or nullif(btrim(p_idempotency_key), '') is null then
    raise exception 'source_application, event_type, channel, message_body and idempotency_key are required';
  end if;

  if p_channel not in ('email','whatsapp','sms','push') then
    raise exception 'unsupported notification channel';
  end if;

  if p_channel = 'email' and nullif(btrim(p_recipient_email), '') is null then
    raise exception 'email recipient required';
  end if;

  if p_channel in ('whatsapp','sms') and nullif(btrim(p_recipient_phone), '') is null then
    raise exception 'phone recipient required';
  end if;

  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'max_attempts must be between 1 and 20';
  end if;

  select * into v_existing
  from public.notification_outbox
  where source_application = p_source_application
    and idempotency_key = p_idempotency_key;

  if found then
    if v_existing.event_type is distinct from p_event_type
       or v_existing.channel is distinct from p_channel
       or v_existing.message_body is distinct from p_message_body
       or v_existing.recipient_email is distinct from p_recipient_email
       or v_existing.recipient_phone is distinct from p_recipient_phone then
      raise exception 'idempotency key conflict';
    end if;
    return v_existing.id;
  end if;

  begin
    insert into public.notification_outbox (
      source_application, event_type, channel, message_body, idempotency_key,
      recipient_email, recipient_phone, priority, event_id, max_attempts,
      next_attempt_at, status, attempt_count, updated_at
    ) values (
      p_source_application, p_event_type, p_channel, p_message_body, p_idempotency_key,
      p_recipient_email, p_recipient_phone, coalesce(p_priority,'normal'), p_event_id,
      p_max_attempts, coalesce(p_next_attempt_at, now()), 'pending', 0, now()
    ) returning id into v_id;
    return v_id;
  exception when unique_violation then
    select * into v_existing
    from public.notification_outbox
    where source_application = p_source_application
      and idempotency_key = p_idempotency_key;
    if not found
       or v_existing.event_type is distinct from p_event_type
       or v_existing.channel is distinct from p_channel
       or v_existing.message_body is distinct from p_message_body
       or v_existing.recipient_email is distinct from p_recipient_email
       or v_existing.recipient_phone is distinct from p_recipient_phone then
      raise exception 'idempotency key conflict';
    end if;
    return v_existing.id;
  end;
end;
$$;

create or replace function public.claim_notification_batch_v1(
  p_worker_id text,
  p_batch_size integer default 25,
  p_lease_seconds integer default 120
)
returns setof public.notification_outbox
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;
  if nullif(btrim(p_worker_id), '') is null then
    raise exception 'worker_id required';
  end if;
  if p_batch_size < 1 or p_batch_size > 100 then
    raise exception 'batch_size must be between 1 and 100';
  end if;

  return query
  with candidates as (
    select id
    from public.notification_outbox
    where status in ('pending','retry')
      and next_attempt_at <= now()
      and attempt_count < max_attempts
      and (locked_at is null or locked_at < now() - make_interval(secs => p_lease_seconds))
    order by
      case priority when 'critical' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
      created_at
    for update skip locked
    limit p_batch_size
  )
  update public.notification_outbox n
  set status='processing',
      locked_at=now(),
      locked_by=p_worker_id,
      last_attempt_at=now(),
      attempt_count=n.attempt_count + 1,
      updated_at=now()
  from candidates c
  where n.id=c.id
  returning n.*;
end;
$$;

create or replace function public.complete_notification_v1(
  p_notification_id uuid,
  p_worker_id text,
  p_provider_message_id text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;
  update public.notification_outbox
  set status='sent', sent_at=now(), provider_message_id=p_provider_message_id,
      locked_at=null, locked_by=null, error_log=null, updated_at=now()
  where id=p_notification_id and status='processing' and locked_by=p_worker_id;
  if not found then raise exception 'notification lease not owned'; end if;
end;
$$;

create or replace function public.fail_notification_v1(
  p_notification_id uuid,
  p_worker_id text,
  p_error text,
  p_retry_delay_seconds integer default 300
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;

  update public.notification_outbox
  set status = case when attempt_count >= max_attempts then 'failed' else 'retry' end,
      next_attempt_at = case when attempt_count >= max_attempts then next_attempt_at else now() + make_interval(secs => greatest(p_retry_delay_seconds,0)) end,
      error_log = left(coalesce(p_error,'unknown delivery error'),4000),
      locked_at=null, locked_by=null, updated_at=now()
  where id=p_notification_id and status='processing' and locked_by=p_worker_id
  returning status into v_status;

  if v_status is null then raise exception 'notification lease not owned'; end if;
  return v_status;
end;
$$;

revoke all on function public.enqueue_notification_v1(text,text,text,text,text,text,text,text,uuid,integer,timestamptz) from public, anon;
grant execute on function public.enqueue_notification_v1(text,text,text,text,text,text,text,text,uuid,integer,timestamptz) to authenticated, service_role;

revoke all on function public.claim_notification_batch_v1(text,integer,integer) from public, anon, authenticated;
revoke all on function public.complete_notification_v1(uuid,text,text) from public, anon, authenticated;
revoke all on function public.fail_notification_v1(uuid,text,text,integer) from public, anon, authenticated;
grant execute on function public.claim_notification_batch_v1(text,integer,integer) to service_role;
grant execute on function public.complete_notification_v1(uuid,text,text) to service_role;
grant execute on function public.fail_notification_v1(uuid,text,text,integer) to service_role;

comment on function public.enqueue_notification_v1(text,text,text,text,text,text,text,text,uuid,integer,timestamptz)
is 'Idempotent governed enqueue operation for the shared notification outbox.';
comment on function public.claim_notification_batch_v1(text,integer,integer)
is 'Service-role-only leased batch claim using SKIP LOCKED.';
comment on function public.complete_notification_v1(uuid,text,text)
is 'Service-role-only successful delivery acknowledgement.';
comment on function public.fail_notification_v1(uuid,text,text,integer)
is 'Service-role-only retry or terminal failure transition.';