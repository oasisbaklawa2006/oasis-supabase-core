-- WhatsApp packet-AI dispatch: bounded retry with a durable terminal state.
--
-- Defect (verified read-only against production 2026-10-22):
--   retry_whatsapp_packet_ai_dispatch_job() rescheduled every failure as RETRY
--   forever (backoff capped at 480s, no attempt ceiling, no terminal state).
--   Five jobs were looping with 157..4934 attempts, including deterministic
--   failures that can never succeed on retry:
--     * INTERPRETATION_PACKET_TOO_LARGE
--     * CASE_MATERIALIZATION_FAILED: multiple potential orders are linked to
--       this communication case (the resolver correctly refuses to pick one).
--   A failure that precedes the interpretation cache (for example an invalid
--   model response) re-invoked the AI provider on every retry, so an unbounded
--   retry is also an unbounded provider-cost loop.
--
-- Repair (additive, DB-only, no Edge change, no data rewrite):
--   * New terminal job state DEAD_LETTERED with class/reason and timestamp.
--   * Bounded attempt budget enforced inside the existing retry RPC (same
--     signature, so the deployed worker is unchanged).
--   * Deterministic failures terminate on the first occurrence.
--   * Ambiguous multiple-potential-order failures terminate as
--     HUMAN_REVIEW_REQUIRED and open a governed department task. No order is
--     ever selected automatically.
--   * Append-only, idempotent event log + operator-visible exceptions view.
--   * Explicit service-role RPCs to dead-letter and to requeue a job. Both are
--     reversible and are the ONLY way to terminate a historical job.
--
-- Historical jobs are NOT auto-dead-lettered. Existing rows receive
-- bounded_retry = false (a catalog default, not a row rewrite) and keep their
-- previous retry behaviour until an operator acts or a new inbound message
-- revises the packet. Jobs created after this migration default to true.

-- -----------------------------------------------------------------------------
-- 1. Job columns, state and shape constraints
-- -----------------------------------------------------------------------------

alter table public.whatsapp_packet_ai_dispatch_jobs
  add column if not exists bounded_retry boolean not null default false,
  add column if not exists retry_budget_used integer not null default 0,
  add column if not exists dead_lettered_at timestamptz,
  add column if not exists dead_letter_class text,
  add column if not exists dead_letter_reason text;

-- Existing rows keep false (legacy behaviour); every future job is bounded.
alter table public.whatsapp_packet_ai_dispatch_jobs
  alter column bounded_retry set default true;

alter table public.whatsapp_packet_ai_dispatch_jobs
  drop constraint if exists whatsapp_packet_ai_dispatch_jobs_state_check;
alter table public.whatsapp_packet_ai_dispatch_jobs
  add constraint whatsapp_packet_ai_dispatch_jobs_state_check
  check (state in ('QUEUED','LEASED','RETRY','BLOCKED_KNOWLEDGE_AUTHORITY','COMPLETED','DEAD_LETTERED'));

alter table public.whatsapp_packet_ai_dispatch_jobs
  add constraint whatsapp_packet_ai_dispatch_budget_nonnegative
  check (retry_budget_used >= 0);

alter table public.whatsapp_packet_ai_dispatch_jobs
  add constraint whatsapp_packet_ai_dispatch_dead_letter_class_check
  check (dead_letter_class is null or dead_letter_class in (
    'DETERMINISTIC','HUMAN_REVIEW_REQUIRED','RETRY_EXHAUSTED','OPERATOR_QUARANTINE'
  ));

alter table public.whatsapp_packet_ai_dispatch_jobs
  add constraint whatsapp_packet_ai_dispatch_dead_letter_shape
  check (
    (state = 'DEAD_LETTERED'
      and dead_lettered_at is not null
      and dead_letter_class is not null
      and nullif(btrim(dead_letter_reason), '') is not null)
    or
    (state <> 'DEAD_LETTERED'
      and dead_lettered_at is null
      and dead_letter_class is null
      and dead_letter_reason is null)
  );

-- Governed attempt budgets live in the platform retry_policies registry so
-- operations can tune them without a code change. Seeding is idempotent and
-- never overwrites an existing (possibly tuned) row.
insert into public.retry_policies(
  policy_key, owning_application, workload_type, max_attempts, base_delay_seconds,
  max_delay_seconds, backoff_multiplier, jitter_percent, dead_letter_enabled, is_active
) values
  ('whatsapp.packet_ai_dispatch.default', 'Supabase Core', 'whatsapp_packet_ai_dispatch', 10, 30, 900, 2.000, 0, true, true),
  ('whatsapp.packet_ai_dispatch.model_output', 'Supabase Core', 'whatsapp_packet_ai_dispatch', 3, 30, 900, 2.000, 0, true, true)
on conflict (policy_key) do nothing;

-- -----------------------------------------------------------------------------
-- 2. Append-only dead-letter event log (operator visibility + audit)
-- -----------------------------------------------------------------------------

create table if not exists public.whatsapp_packet_ai_dispatch_dead_letter_events (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.whatsapp_packet_ai_dispatch_jobs(id) on delete restrict,
  packet_id uuid not null,
  case_id uuid,
  event_type text not null check (event_type in (
    'DEAD_LETTERED','OPERATOR_DEAD_LETTERED','OPERATOR_REQUEUED','REVIVED_BY_NEW_REVISION'
  )),
  dead_letter_class text,
  reason text,
  error_code text,
  attempt_count integer,
  retry_budget_used integer,
  actor_type text not null default 'SYSTEM' check (actor_type in ('SYSTEM','OPERATOR')),
  actor_id uuid,
  idempotency_key text not null,
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_packet_ai_dispatch_dead_letter_events_idempotency_key
    unique (idempotency_key)
);

create index if not exists whatsapp_packet_ai_dispatch_dead_letter_events_job_idx
  on public.whatsapp_packet_ai_dispatch_dead_letter_events (job_id, created_at);

create or replace function public.prevent_whatsapp_packet_ai_dispatch_dead_letter_event_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception 'whatsapp_packet_ai_dispatch_dead_letter_events is append-only'
    using errcode = '42501';
end $$;

revoke all on function public.prevent_whatsapp_packet_ai_dispatch_dead_letter_event_mutation()
  from public, anon, authenticated;

drop trigger if exists whatsapp_packet_ai_dispatch_dead_letter_events_append_only
  on public.whatsapp_packet_ai_dispatch_dead_letter_events;
create trigger whatsapp_packet_ai_dispatch_dead_letter_events_append_only
  before update or delete on public.whatsapp_packet_ai_dispatch_dead_letter_events
  for each row execute function public.prevent_whatsapp_packet_ai_dispatch_dead_letter_event_mutation();

alter table public.whatsapp_packet_ai_dispatch_dead_letter_events enable row level security;

drop policy if exists whatsapp_packet_ai_dispatch_dead_letter_events_service_role
  on public.whatsapp_packet_ai_dispatch_dead_letter_events;
create policy whatsapp_packet_ai_dispatch_dead_letter_events_service_role
  on public.whatsapp_packet_ai_dispatch_dead_letter_events
  to service_role using (true) with check (true);

drop policy if exists whatsapp_packet_ai_dispatch_dead_letter_events_reader
  on public.whatsapp_packet_ai_dispatch_dead_letter_events;
create policy whatsapp_packet_ai_dispatch_dead_letter_events_reader
  on public.whatsapp_packet_ai_dispatch_dead_letter_events
  for select to authenticated
  using (public.is_whatsapp_inbox_reader(auth.uid()));

revoke all on public.whatsapp_packet_ai_dispatch_dead_letter_events from public, anon, authenticated;
grant select on public.whatsapp_packet_ai_dispatch_dead_letter_events to authenticated;
grant all on public.whatsapp_packet_ai_dispatch_dead_letter_events to service_role;

-- -----------------------------------------------------------------------------
-- 3. Revival / enrolment trigger
--    * A dead-lettered job that leaves DEAD_LETTERED (operator requeue, or a new
--      inbound revision re-queued by the existing enqueue upsert) clears its
--      terminal markers and receives a fresh attempt budget.
--    * A new packet revision is new work: it enrols a legacy job in bounded
--      retry. It never terminates anything.
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_packet_ai_dispatch_job_revive()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if old.state = 'DEAD_LETTERED' and new.state <> 'DEAD_LETTERED' then
    update public.dead_letter_entries
    set status = 'requeued', requeued_at = statement_timestamp(), updated_at = statement_timestamp(),
        resolution_note = coalesce(resolution_note, 'dispatch job re-queued')
    where source_table = 'whatsapp_packet_ai_dispatch_jobs'
      and source_record_id = new.id::text and status = 'open';
    new.dead_lettered_at := null;
    new.dead_letter_class := null;
    new.dead_letter_reason := null;
    new.retry_budget_used := 0;
    new.bounded_retry := true;
    if new.packet_revision is distinct from old.packet_revision then
      insert into public.whatsapp_packet_ai_dispatch_dead_letter_events(
        job_id, packet_id, case_id, event_type, dead_letter_class, reason, error_code,
        attempt_count, retry_budget_used, actor_type, idempotency_key, details
      ) values (
        new.id, new.packet_id, new.case_id, 'REVIVED_BY_NEW_REVISION',
        old.dead_letter_class, old.dead_letter_reason, old.last_error_code,
        old.attempt_count, old.retry_budget_used, 'SYSTEM',
        'revived:' || new.id::text || ':revision:' || new.packet_revision::text,
        jsonb_build_object('previous_revision', old.packet_revision, 'new_revision', new.packet_revision)
      )
      on conflict (idempotency_key) do nothing;
    end if;
  elsif new.packet_revision is distinct from old.packet_revision then
    new.bounded_retry := true;
    new.retry_budget_used := 0;
  end if;
  return new;
end $$;

revoke all on function public.whatsapp_packet_ai_dispatch_job_revive() from public, anon, authenticated;

drop trigger if exists whatsapp_packet_ai_dispatch_job_revive
  on public.whatsapp_packet_ai_dispatch_jobs;
create trigger whatsapp_packet_ai_dispatch_job_revive
  before update on public.whatsapp_packet_ai_dispatch_jobs
  for each row execute function public.whatsapp_packet_ai_dispatch_job_revive();

-- -----------------------------------------------------------------------------
-- 4. Bounded retry, crash-loop bounding and the single terminal-transition helper
-- -----------------------------------------------------------------------------

-- Internal: the ONLY place an automatic dead-letter is written, so the job row,
-- the platform dead-letter console entry, the append-only audit event and the
-- governed human-review task can never diverge. Idempotent per
-- (job, attempt): a repeated call for a job that is already terminal is a no-op.
create or replace function public.whatsapp_packet_ai_dispatch_dead_letter_v1(
  p_job_id uuid,
  p_class text,
  p_reason text,
  p_error_code text,
  p_error_detail text,
  p_policy_key text
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype;
  v_code text := left(btrim(coalesce(p_error_code, '')), 120);
  v_detail text := left(btrim(coalesce(p_error_detail, '')), 500);
  v_case_id uuid;
  v_actor uuid;
  v_task_created boolean := false;
  v_rows integer;
begin
  select * into v_job from public.whatsapp_packet_ai_dispatch_jobs
  where id = p_job_id and state in ('LEASED', 'QUEUED', 'RETRY', 'BLOCKED_KNOWLEDGE_AUTHORITY')
  for update;
  if not found then return false; end if;

  update public.whatsapp_packet_ai_dispatch_jobs j
  set state = 'DEAD_LETTERED', retry_budget_used = j.retry_budget_used + 1,
      claimed_at = null, lease_expires_at = null, lease_token = null,
      last_error_code = nullif(v_code, ''), last_error_detail = nullif(v_detail, ''),
      next_retry_at = statement_timestamp(),
      dead_lettered_at = statement_timestamp(),
      dead_letter_class = p_class, dead_letter_reason = p_reason,
      updated_at = statement_timestamp()
  where j.id = v_job.id;

  v_case_id := coalesce(
    v_job.case_id,
    (select c.id from public.whatsapp_communication_cases c where c.packet_id = v_job.packet_id)
  );

  if p_class = 'HUMAN_REVIEW_REQUIRED' and v_case_id is not null then
    v_actor := public.whatsapp_core_c_system_principal_id();
    if v_actor is not null
       and exists (
         select 1 from public.whatsapp_communication_cases c
         where c.id = v_case_id and c.status not in ('CLOSED', 'CANCELLED')
       ) then
      insert into public.whatsapp_case_department_tasks(
        case_id, department, task_type, instructions, status, due_at, correlation_key, created_by
      ) values (
        v_case_id, 'OPERATIONS', 'AMBIGUOUS_POTENTIAL_ORDER_REVIEW',
        'Multiple potential orders are linked to this communication case. Automated order '
        || 'materialisation stopped; no order was selected. Review the linked potential orders, '
        || 'decide the correct one (or split the conversation) and re-queue the dispatch job.',
        'OPEN', statement_timestamp() + interval '1 day',
        'dispatch-dead-letter:' || v_job.id::text, v_actor
      )
      on conflict (case_id, correlation_key) do nothing;
      get diagnostics v_rows = row_count;
      v_task_created := v_rows = 1;

      insert into public.whatsapp_case_events(case_id, event_type, actor_type, correlation_key, metadata)
      values (
        v_case_id, 'AMBIGUOUS_POTENTIAL_ORDERS_ROUTED_TO_HUMAN_REVIEW', 'SYSTEM',
        'dispatch-dead-letter:' || v_job.id::text,
        jsonb_build_object('dispatch_job_id', v_job.id, 'packet_id', v_job.packet_id,
          'attempt_count', v_job.attempt_count)
      )
      on conflict (case_id, correlation_key) do nothing;
    end if;
  end if;

  insert into public.dead_letter_entries(
    source_application, workload_type, source_table, source_record_id, policy_key,
    idempotency_key, attempt_count, error_code, error_message, context
  ) values (
    'Supabase Core', 'whatsapp_packet_ai_dispatch', 'whatsapp_packet_ai_dispatch_jobs', v_job.id::text,
    p_policy_key, 'dead-letter:' || v_job.id::text || ':attempt:' || v_job.attempt_count::text,
    greatest(v_job.attempt_count, 1), nullif(v_code, ''), coalesce(nullif(v_detail, ''), nullif(v_code, ''), p_reason),
    jsonb_build_object('dead_letter_class', p_class, 'dead_letter_reason', p_reason,
      'packet_id', v_job.packet_id, 'case_id', v_case_id, 'execution_kind', v_job.execution_kind)
  )
  on conflict (source_table, source_record_id) where status = 'open'
  do update set attempt_count = greatest(public.dead_letter_entries.attempt_count, excluded.attempt_count),
    error_code = excluded.error_code, error_message = excluded.error_message,
    context = excluded.context, last_failed_at = statement_timestamp(), updated_at = statement_timestamp();

  insert into public.whatsapp_packet_ai_dispatch_dead_letter_events(
    job_id, packet_id, case_id, event_type, dead_letter_class, reason, error_code,
    attempt_count, retry_budget_used, actor_type, idempotency_key, details
  ) values (
    v_job.id, v_job.packet_id, v_case_id, 'DEAD_LETTERED', p_class, p_reason, nullif(v_code, ''),
    v_job.attempt_count, v_job.retry_budget_used + 1, 'SYSTEM',
    'dead-letter:' || v_job.id::text || ':attempt:' || v_job.attempt_count::text,
    jsonb_build_object('detail', nullif(v_detail, ''), 'policy_key', p_policy_key,
      'human_review_task_created', v_task_created)
  )
  on conflict (idempotency_key) do nothing;

  return true;
end $$;

revoke all on function public.whatsapp_packet_ai_dispatch_dead_letter_v1(uuid, text, text, text, text, text)
  from public, anon, authenticated, service_role;

create or replace function public.retry_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid,
  p_lease_token uuid,
  p_packet_revision bigint,
  p_error_code text,
  p_error_detail text default null,
  p_knowledge_authority_failure boolean default false
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype;
  v_code text := left(btrim(coalesce(p_error_code, '')), 120);
  v_detail text := left(btrim(coalesce(p_error_detail, '')), 500);
  v_class text;
  v_reason text;
  v_budget integer;
  v_policy_key text;
  v_delay interval;
begin
  if v_code = '' then raise exception 'error code required' using errcode = '22023'; end if;

  select j.* into v_job
  from public.whatsapp_packet_ai_dispatch_jobs j
  where j.id = p_job_id and j.state = 'LEASED' and j.lease_token = p_lease_token
    and j.packet_revision = p_packet_revision
    and (j.execution_kind = 'PACKET' or exists (
      select 1 from public.whatsapp_communication_cases c
      where c.id = j.case_id and c.context_revision = j.context_revision
    ))
  for update;
  if not found then return false; end if;

  v_delay := make_interval(secs => least(900, 15 * power(2, least(v_job.attempt_count, 5))::integer));

  -- Governed knowledge-authority blocks keep their existing semantics.
  -- Legacy (pre-bounded) jobs keep the previous behaviour until an operator
  -- acts or a new revision enrols them.
  -- The deployed worker flags every KNOWLEDGE_SNAPSHOT_* error as a
  -- knowledge-authority failure, including the deterministic
  -- KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE, which can never succeed on retry.
  -- For bounded jobs that one code is therefore classified below instead.
  if (p_knowledge_authority_failure
        and not (v_job.bounded_retry and v_code = 'KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE'))
     or not v_job.bounded_retry then
    update public.whatsapp_packet_ai_dispatch_jobs j
    set state = case when p_knowledge_authority_failure then 'BLOCKED_KNOWLEDGE_AUTHORITY' else 'RETRY' end,
        claimed_at = null, lease_expires_at = null, lease_token = null,
        last_error_code = v_code, last_error_detail = nullif(v_detail, ''),
        next_retry_at = statement_timestamp() + v_delay,
        updated_at = statement_timestamp()
    where j.id = v_job.id;
    return true;
  end if;

  v_policy_key := case
    when v_code in ('INTERPRETER_INVALID_SCHEMA', 'INTERPRETER_INVALID_JSON')
      then 'whatsapp.packet_ai_dispatch.model_output'
    else 'whatsapp.packet_ai_dispatch.default'
  end;
  v_budget := coalesce(
    (select rp.max_attempts from public.retry_policies rp where rp.policy_key = v_policy_key and rp.is_active),
    case when v_policy_key like '%model_output' then 3 else 10 end
  );

  if v_code in (
    'INTERPRETATION_PACKET_TOO_LARGE', 'PACKET_EMPTY', 'CASE_CONTEXT_EMPTY',
    'PACKET_NOT_FOUND', 'PACKET_MEDIA_TOO_LARGE', 'KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE'
  ) then
    v_class := 'DETERMINISTIC';
    v_reason := v_code;
  elsif v_code = 'CASE_MATERIALIZATION_FAILED'
        and v_detail ilike '%multiple potential orders are linked%' then
    v_class := 'HUMAN_REVIEW_REQUIRED';
    v_reason := 'AMBIGUOUS_POTENTIAL_ORDERS';
  elsif v_job.retry_budget_used + 1 >= v_budget then
    v_class := 'RETRY_EXHAUSTED';
    v_reason := v_code || ':attempt budget ' || v_budget::text || ' exhausted';
  end if;

  if v_class is null then
    update public.whatsapp_packet_ai_dispatch_jobs j
    set state = 'RETRY', retry_budget_used = j.retry_budget_used + 1,
        claimed_at = null, lease_expires_at = null, lease_token = null,
        last_error_code = v_code, last_error_detail = nullif(v_detail, ''),
        next_retry_at = statement_timestamp() + v_delay,
        updated_at = statement_timestamp()
    where j.id = v_job.id;
    return true;
  end if;

  return public.whatsapp_packet_ai_dispatch_dead_letter_v1(
    v_job.id, v_class, v_reason, v_code, v_detail, v_policy_key
  );
end $$;

revoke all on function public.retry_whatsapp_packet_ai_dispatch_job(uuid, uuid, bigint, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.retry_whatsapp_packet_ai_dispatch_job(uuid, uuid, bigint, text, text, boolean)
  to service_role;

-- Crash-loop bounding. A worker that times out or crashes never reports a
-- failure; its lease simply expires and the job is re-leased. Each such reclaim
-- now spends one unit of the same budget, so a poison packet that kills the
-- worker (and re-invokes the AI provider every time) terminates too.
create or replace function public.claim_whatsapp_packet_ai_dispatch_job(p_lease_seconds integer default 120)
returns public.whatsapp_packet_ai_dispatch_jobs
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype;
  v_budget integer;
  v_exhausted uuid;
begin
  if p_lease_seconds < 30 or p_lease_seconds > 900 then
    raise exception 'lease duration must be between 30 and 900 seconds' using errcode = '22023';
  end if;

  v_budget := coalesce(
    (select rp.max_attempts from public.retry_policies rp
      where rp.policy_key = 'whatsapp.packet_ai_dispatch.default' and rp.is_active),
    10
  );

  for v_exhausted in
    select j.id from public.whatsapp_packet_ai_dispatch_jobs j
    where j.state = 'LEASED' and j.lease_expires_at <= statement_timestamp()
      and j.bounded_retry and j.retry_budget_used + 1 >= v_budget
    order by j.created_at
    for update skip locked
  loop
    perform public.whatsapp_packet_ai_dispatch_dead_letter_v1(
      v_exhausted, 'RETRY_EXHAUSTED', 'WORKER_LEASE_EXPIRED_REPEATEDLY',
      'WORKER_LEASE_EXPIRED',
      'worker lease expired without a result; attempt budget ' || v_budget::text || ' exhausted',
      'whatsapp.packet_ai_dispatch.default'
    );
  end loop;

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
      retry_budget_used = case when j.state = 'LEASED' and j.bounded_retry
                               then j.retry_budget_used + 1 else j.retry_budget_used end,
      claimed_at=statement_timestamp(), last_attempt_at=statement_timestamp(),
      lease_expires_at=statement_timestamp() + make_interval(secs => p_lease_seconds),
      lease_token=gen_random_uuid(), next_retry_at=statement_timestamp(),
      updated_at=statement_timestamp()
  from candidate where j.id=candidate.id
  returning j.* into v_job;
  return v_job;
end $$;

revoke all on function public.claim_whatsapp_packet_ai_dispatch_job(integer) from public, anon, authenticated;
grant execute on function public.claim_whatsapp_packet_ai_dispatch_job(integer) to service_role;

-- -----------------------------------------------------------------------------
-- 5. Explicit, reversible operator RPCs (service_role only)
-- -----------------------------------------------------------------------------

create or replace function public.dead_letter_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid,
  p_reason text,
  p_actor_id uuid,
  p_idempotency_key text
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype; v_reason text := left(btrim(coalesce(p_reason, '')), 500);
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if p_actor_id is null or nullif(btrim(coalesce(p_idempotency_key, '')), '') is null or length(v_reason) < 5 then
    raise exception 'actor, idempotency key and reason (>= 5 chars) required' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.whatsapp_packet_ai_dispatch_dead_letter_events
    where idempotency_key = 'operator-dead-letter:' || p_idempotency_key
  ) then
    return true;
  end if;

  select * into v_job from public.whatsapp_packet_ai_dispatch_jobs
  where id = p_job_id
    and (state in ('QUEUED', 'RETRY', 'BLOCKED_KNOWLEDGE_AUTHORITY')
         or (state = 'LEASED' and lease_expires_at <= statement_timestamp()))
  for update;
  if not found then return false; end if;

  update public.whatsapp_packet_ai_dispatch_jobs
  set state = 'DEAD_LETTERED', claimed_at = null, lease_expires_at = null, lease_token = null,
      dead_lettered_at = statement_timestamp(), dead_letter_class = 'OPERATOR_QUARANTINE',
      dead_letter_reason = v_reason, updated_at = statement_timestamp()
  where id = v_job.id;

  insert into public.dead_letter_entries(
    source_application, workload_type, source_table, source_record_id, policy_key,
    idempotency_key, attempt_count, error_code, error_message, context
  ) values (
    'Supabase Core', 'whatsapp_packet_ai_dispatch', 'whatsapp_packet_ai_dispatch_jobs', v_job.id::text,
    'whatsapp.packet_ai_dispatch.default', 'operator-dead-letter:' || p_idempotency_key,
    greatest(v_job.attempt_count, 1), coalesce(v_job.last_error_code, 'OPERATOR_QUARANTINE'), v_reason,
    jsonb_build_object('dead_letter_class', 'OPERATOR_QUARANTINE', 'actor_id', p_actor_id,
      'packet_id', v_job.packet_id, 'case_id', v_job.case_id, 'previous_state', v_job.state)
  )
  on conflict (source_table, source_record_id) where status = 'open'
  do update set error_message = excluded.error_message, context = excluded.context,
    last_failed_at = statement_timestamp(), updated_at = statement_timestamp();

  insert into public.whatsapp_packet_ai_dispatch_dead_letter_events(
    job_id, packet_id, case_id, event_type, dead_letter_class, reason, error_code,
    attempt_count, retry_budget_used, actor_type, actor_id, idempotency_key, details
  ) values (
    v_job.id, v_job.packet_id, v_job.case_id, 'OPERATOR_DEAD_LETTERED', 'OPERATOR_QUARANTINE',
    v_reason, v_job.last_error_code, v_job.attempt_count, v_job.retry_budget_used,
    'OPERATOR', p_actor_id, 'operator-dead-letter:' || p_idempotency_key,
    jsonb_build_object('previous_state', v_job.state, 'bounded_retry', v_job.bounded_retry)
  );
  return true;
end $$;

create or replace function public.requeue_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid,
  p_reason text,
  p_actor_id uuid,
  p_idempotency_key text
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype; v_reason text := left(btrim(coalesce(p_reason, '')), 500);
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if p_actor_id is null or nullif(btrim(coalesce(p_idempotency_key, '')), '') is null or length(v_reason) < 5 then
    raise exception 'actor, idempotency key and reason (>= 5 chars) required' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.whatsapp_packet_ai_dispatch_dead_letter_events
    where idempotency_key = 'operator-requeue:' || p_idempotency_key
  ) then
    return true;
  end if;

  select * into v_job from public.whatsapp_packet_ai_dispatch_jobs
  where id = p_job_id and state = 'DEAD_LETTERED'
  for update;
  if not found then return false; end if;

  -- The revive trigger clears the terminal markers and resets the budget.
  update public.whatsapp_packet_ai_dispatch_jobs
  set state = 'QUEUED', next_retry_at = statement_timestamp(),
      last_error_code = null, last_error_detail = null,
      updated_at = statement_timestamp()
  where id = v_job.id;

  insert into public.whatsapp_packet_ai_dispatch_dead_letter_events(
    job_id, packet_id, case_id, event_type, dead_letter_class, reason, error_code,
    attempt_count, retry_budget_used, actor_type, actor_id, idempotency_key, details
  ) values (
    v_job.id, v_job.packet_id, v_job.case_id, 'OPERATOR_REQUEUED', v_job.dead_letter_class,
    v_reason, v_job.last_error_code, v_job.attempt_count, v_job.retry_budget_used,
    'OPERATOR', p_actor_id, 'operator-requeue:' || p_idempotency_key,
    jsonb_build_object('previous_reason', v_job.dead_letter_reason)
  );
  return true;
end $$;

revoke all on function public.dead_letter_whatsapp_packet_ai_dispatch_job(uuid, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.dead_letter_whatsapp_packet_ai_dispatch_job(uuid, text, uuid, text)
  to service_role;
revoke all on function public.requeue_whatsapp_packet_ai_dispatch_job(uuid, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.requeue_whatsapp_packet_ai_dispatch_job(uuid, text, uuid, text)
  to service_role;

-- -----------------------------------------------------------------------------
-- 6. Operator visibility
--    Terminal jobs plus any job still retrying past the bounded budget
--    (legacy unbounded jobs are surfaced, never hidden).
-- -----------------------------------------------------------------------------

create or replace view public.whatsapp_packet_ai_dispatch_exceptions_v
with (security_invoker = true) as
select
  j.id as job_id,
  j.packet_id,
  j.case_id,
  j.execution_kind,
  j.state,
  j.dead_letter_class,
  j.dead_letter_reason,
  j.last_error_code,
  j.attempt_count,
  j.retry_budget_used,
  j.bounded_retry,
  j.dead_lettered_at,
  j.next_retry_at,
  j.created_at,
  (j.state <> 'DEAD_LETTERED') as still_retrying
from public.whatsapp_packet_ai_dispatch_jobs j
where j.state = 'DEAD_LETTERED'
   or (j.state in ('RETRY', 'BLOCKED_KNOWLEDGE_AUTHORITY', 'LEASED') and j.attempt_count >= 10);

-- Service role only: the jobs table has no end-user policy. Operators see the
-- same facts through the append-only event log (inbox-reader policy) and the
-- platform dead-letter console (administrator policy).
revoke all on public.whatsapp_packet_ai_dispatch_exceptions_v from public, anon, authenticated;
grant select on public.whatsapp_packet_ai_dispatch_exceptions_v to service_role;

comment on view public.whatsapp_packet_ai_dispatch_exceptions_v is
  'Service-role view of dead-lettered packet-AI dispatch jobs and jobs still retrying or crash-looping beyond ten attempts (including legacy unbounded jobs).';
