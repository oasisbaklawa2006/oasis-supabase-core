-- Durable, database-owned outbox.  The trigger runs in the same transaction as
-- the canonical stitcher assigning whatsapp_messages.packet_id.
begin;

alter table public.whatsapp_message_packets
  add column if not exists ai_dispatch_revision bigint not null default 0;

create table public.whatsapp_packet_ai_dispatch_jobs (
  id uuid primary key default gen_random_uuid(),
  packet_id uuid not null unique references public.whatsapp_message_packets(id) on delete restrict,
  packet_revision bigint not null check (packet_revision > 0),
  logical_dispatch_key text not null unique,
  state text not null default 'QUEUED' check (state in ('QUEUED','LEASED','RETRY','BLOCKED_KNOWLEDGE_AUTHORITY','COMPLETED')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  claimed_at timestamptz,
  lease_expires_at timestamptz,
  lease_token uuid,
  last_attempt_at timestamptz,
  last_error_code text check (last_error_code is null or length(last_error_code) <= 120),
  last_error_detail text,
  next_retry_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_packet_ai_dispatch_lease_shape check (
    (state = 'LEASED' and claimed_at is not null and lease_expires_at is not null and lease_token is not null)
    or (state <> 'LEASED' and claimed_at is null and lease_expires_at is null and lease_token is null)
  ),
  constraint whatsapp_packet_ai_dispatch_detail_bound check (last_error_detail is null or length(last_error_detail) <= 500)
);
create index whatsapp_packet_ai_dispatch_claim_idx on public.whatsapp_packet_ai_dispatch_jobs (state, next_retry_at, created_at);

alter table public.whatsapp_packet_ai_dispatch_jobs enable row level security;
revoke all on public.whatsapp_packet_ai_dispatch_jobs from public, anon, authenticated;
grant select, insert, update on public.whatsapp_packet_ai_dispatch_jobs to service_role;
revoke delete on public.whatsapp_packet_ai_dispatch_jobs from service_role;

create or replace function public.enqueue_whatsapp_packet_ai_dispatch()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_revision bigint; v_key text;
begin
  if lower(new.direction) <> 'inbound'
     or new.packet_id is null
     or (tg_op = 'UPDATE' and new.packet_id is not distinct from old.packet_id) then
    return new;
  end if;
  update public.whatsapp_message_packets set ai_dispatch_revision = ai_dispatch_revision + 1, updated_at = statement_timestamp()
    where id = new.packet_id returning ai_dispatch_revision into v_revision;
  v_key := 'packet:' || new.packet_id::text || ':revision:' || v_revision::text;
  insert into public.whatsapp_packet_ai_dispatch_jobs(packet_id,packet_revision,logical_dispatch_key)
    values(new.packet_id,v_revision,v_key)
  on conflict(packet_id) do update set
    packet_revision=excluded.packet_revision, logical_dispatch_key=excluded.logical_dispatch_key,
    state=case when public.whatsapp_packet_ai_dispatch_jobs.state='LEASED' then 'LEASED' else 'QUEUED' end,
    next_retry_at=statement_timestamp(), last_error_code=null, last_error_detail=null, completed_at=null, updated_at=statement_timestamp();
  return new;
end $$;

drop trigger if exists whatsapp_messages_enqueue_packet_ai_dispatch on public.whatsapp_messages;
create trigger whatsapp_messages_enqueue_packet_ai_dispatch
after insert or update of packet_id on public.whatsapp_messages
for each row execute function public.enqueue_whatsapp_packet_ai_dispatch();

revoke all on function public.enqueue_whatsapp_packet_ai_dispatch() from public, anon, authenticated, service_role;

-- A claim is exclusive, including recovery of a crashed worker after lease
-- expiry.  The returned token/revision is required for every later mutation.
create or replace function public.claim_whatsapp_packet_ai_dispatch_job(
  p_lease_seconds integer default 120
)
returns public.whatsapp_packet_ai_dispatch_jobs
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype;
begin
  if p_lease_seconds < 30 or p_lease_seconds > 900 then
    raise exception 'lease duration must be between 30 and 900 seconds' using errcode='22023';
  end if;
  with candidate as (
    select id from public.whatsapp_packet_ai_dispatch_jobs
    where (
      state in ('QUEUED','RETRY','BLOCKED_KNOWLEDGE_AUTHORITY') and next_retry_at <= statement_timestamp()
    ) or (
      state = 'LEASED' and lease_expires_at <= statement_timestamp()
    )
    order by next_retry_at, created_at
    for update skip locked
    limit 1
  )
  update public.whatsapp_packet_ai_dispatch_jobs j
  set state='LEASED', attempt_count=j.attempt_count+1,
      claimed_at=statement_timestamp(), last_attempt_at=statement_timestamp(),
      lease_expires_at=statement_timestamp() + make_interval(secs => p_lease_seconds),
      lease_token=gen_random_uuid(), next_retry_at=statement_timestamp(),
      updated_at=statement_timestamp()
  from candidate where j.id=candidate.id
  returning j.* into v_job;
  return v_job;
end $$;

-- The worker calls this immediately before durable interpretation and outcome
-- effects.  A new packet revision invalidates the old lease without allowing it
-- to materialize an obsolete result.
create or replace function public.assert_whatsapp_packet_ai_dispatch_lease(
  p_job_id uuid, p_lease_token uuid, p_packet_revision bigint
)
returns boolean language sql security definer set search_path = pg_catalog, public as $$
  select exists(
    select 1 from public.whatsapp_packet_ai_dispatch_jobs
    where id=p_job_id and state='LEASED' and lease_token=p_lease_token
      and packet_revision=p_packet_revision and lease_expires_at > statement_timestamp()
  );
$$;

create or replace function public.complete_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid, p_lease_token uuid, p_packet_revision bigint
)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_updated integer;
begin
  update public.whatsapp_packet_ai_dispatch_jobs
  set state='COMPLETED', claimed_at=null, lease_expires_at=null, lease_token=null,
      completed_at=statement_timestamp(), last_error_code=null, last_error_detail=null,
      updated_at=statement_timestamp()
  where id=p_job_id and state='LEASED' and lease_token=p_lease_token
    and packet_revision=p_packet_revision and lease_expires_at > statement_timestamp();
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end $$;

create or replace function public.retry_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid, p_lease_token uuid, p_packet_revision bigint,
  p_error_code text, p_error_detail text default null, p_knowledge_authority_failure boolean default false
)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_updated integer; v_code text:=left(btrim(coalesce(p_error_code,'')),120); v_detail text:=left(btrim(coalesce(p_error_detail,'')),500);
begin
  if v_code='' then raise exception 'error code required' using errcode='22023'; end if;
  update public.whatsapp_packet_ai_dispatch_jobs
  set state=case when p_knowledge_authority_failure then 'BLOCKED_KNOWLEDGE_AUTHORITY' else 'RETRY' end,
      claimed_at=null, lease_expires_at=null, lease_token=null,
      last_error_code=v_code, last_error_detail=nullif(v_detail,''),
      next_retry_at=statement_timestamp() + make_interval(secs => least(900, 15 * power(2, least(attempt_count, 5))::integer)),
      updated_at=statement_timestamp()
  where id=p_job_id and state='LEASED' and lease_token=p_lease_token
    and packet_revision=p_packet_revision;
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end $$;

-- Release an obsolete lease to the newest revision without treating it as a
-- successful outcome. This is used only when a new packet revision arrived
-- while an older execution was in flight.
create or replace function public.release_superseded_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid, p_lease_token uuid, p_claimed_packet_revision bigint
)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_updated integer;
begin
  update public.whatsapp_packet_ai_dispatch_jobs
  set state='QUEUED', claimed_at=null, lease_expires_at=null, lease_token=null,
      next_retry_at=statement_timestamp(), updated_at=statement_timestamp()
  where id=p_job_id and state='LEASED' and lease_token=p_lease_token
    and packet_revision <> p_claimed_packet_revision;
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end $$;

revoke all on function public.claim_whatsapp_packet_ai_dispatch_job(integer) from public, anon, authenticated;
revoke all on function public.assert_whatsapp_packet_ai_dispatch_lease(uuid,uuid,bigint) from public, anon, authenticated;
revoke all on function public.complete_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint) from public, anon, authenticated;
revoke all on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean) from public, anon, authenticated;
revoke all on function public.release_superseded_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint) from public, anon, authenticated;
grant execute on function public.claim_whatsapp_packet_ai_dispatch_job(integer) to service_role;
grant execute on function public.assert_whatsapp_packet_ai_dispatch_lease(uuid,uuid,bigint) to service_role;
grant execute on function public.complete_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint) to service_role;
grant execute on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean) to service_role;
grant execute on function public.release_superseded_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint) to service_role;

comment on table public.whatsapp_packet_ai_dispatch_jobs is 'Durable Core outbox. A packet-ready transition and its job enqueue are atomic; rows are claimed only by trusted workers and retain retriable failure diagnostics.';
commit;
