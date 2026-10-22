begin;
-- Contract test for migration 20261022120000_whatsapp_packet_ai_dispatch_bounded_retry.
-- Bounded retry + durable dead-letter for the WhatsApp packet-AI dispatch outbox.
-- Covers: bounded transient retry, deterministic termination, bounded AI-call
-- budget, ambiguous potential orders routed to governed human review (never an
-- arbitrary order), idempotency / duplicate delivery, legacy-job preservation,
-- revival on a new revision, reversible operator RPCs, append-only audit,
-- visibility and privilege boundaries.
select plan(70);

-- ---------------------------------------------------------------- fixtures --
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86500000-0000-0000-0000-000000000001', '919650000001', 'transient'),
  ('86500000-0000-0000-0000-000000000002', '919650000002', 'deterministic'),
  ('86500000-0000-0000-0000-000000000003', '919650000003', 'ambiguous'),
  ('86500000-0000-0000-0000-000000000004', '919650000004', 'legacy'),
  ('86500000-0000-0000-0000-000000000005', '919650000005', 'schema'),
  ('86500000-0000-0000-0000-000000000006', '919650000006', 'operator'),
  ('86500000-0000-0000-0000-000000000007', '919650000007', 'tuned'),
  ('86500000-0000-0000-0000-000000000008', '919650000008', 'crash'),
  ('86500000-0000-0000-0000-000000000009', '919650000009', 'crash-legacy'),
  ('86500000-0000-0000-0000-000000000010', '919650000010', 'knowledge-bounded'),
  ('86500000-0000-0000-0000-000000000011', '919650000011', 'knowledge-legacy');

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id, status, message_timestamp, created_at
)
select ('86500000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid,
       ('86500000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'inbound', 'text', 'm' || n, 'click2api', 'bounded-' || n, 'received',
       '2026-10-22 10:00:00', '2026-10-22 10:00:00'
from generate_series(1, 11) n;

select lives_ok($$
  select public.stitch_whatsapp_messages_atomic(
    ('86500000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
    array[('86500000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid], 300)
  from generate_series(1, 11) n
$$, 'eleven isolated packets are stitched, each enqueuing one dispatch job');

create temporary table pk as
select ct.phone_number, p.id as packet_id, j.id as job_id
from public.whatsapp_message_packets p
join public.whatsapp_contacts ct on ct.id = p.contact_id
join public.whatsapp_packet_ai_dispatch_jobs j on j.packet_id = p.id
where ct.id::text like '86500000-%';

-- Isolate the claim queue to one fixture job at a time.
create or replace function pg_temp.only_claimable(p_job uuid) returns void language sql as $$
  update public.whatsapp_packet_ai_dispatch_jobs
  set next_retry_at = case when id = p_job then statement_timestamp() - interval '1 second'
                           else statement_timestamp() + interval '1 day' end
  where state in ('QUEUED', 'RETRY');
$$;

-- Fail the (single) claimable job once; returns the retry RPC result.
create or replace function pg_temp.fail_once(p_job uuid, p_code text, p_detail text default null, p_knowledge boolean default false)
returns boolean language plpgsql as $$
declare c public.whatsapp_packet_ai_dispatch_jobs%rowtype;
begin
  perform pg_temp.only_claimable(p_job);
  select * into c from public.claim_whatsapp_packet_ai_dispatch_job(120);
  if c.id is null then return null; end if;
  return public.retry_whatsapp_packet_ai_dispatch_job(c.id, c.lease_token, c.packet_revision, p_code, p_detail, p_knowledge);
end $$;

select is(
  (select count(*) from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where j.bounded_retry),
  11::bigint, 'jobs created after the migration default to bounded_retry = true');

select is((select count(*)::int from public.retry_policies where policy_key like 'whatsapp.packet_ai_dispatch.%' and is_active and dead_letter_enabled),
  2, 'governed retry policies are seeded for the dispatch workload');

-- ---------------------------------------- 1. transient failures are bounded --
create temporary table transient_claims(n int);
do $$
declare v_job uuid; i int; ok boolean;
begin
  select job_id into v_job from pk where phone_number = '919650000001';
  for i in 1..40 loop
    ok := pg_temp.fail_once(v_job, 'GEMINI_UNAVAILABLE', 'upstream 503');
    exit when ok is null;
    insert into transient_claims values (i);
  end loop;
end $$;

select is((select state from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000001'),
  'DEAD_LETTERED', 'a transient failure repeated for 40 deliveries ends in the durable DEAD_LETTERED state');
select is((select count(*)::int from transient_claims), 10,
  'AI-provider invocations (claims) are bounded to the 10-attempt budget, not 40');
select is((select dead_letter_class from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000001'),
  'RETRY_EXHAUSTED', 'exhaustion is classified RETRY_EXHAUSTED');
select is((select retry_budget_used from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000001'),
  10, 'the full budget of 10 is recorded');
select ok((select dead_lettered_at is not null and last_error_code = 'GEMINI_UNAVAILABLE'
           from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000001'),
  'terminal row preserves the last error evidence and timestamp');
select is((select count(*)::int from public.whatsapp_packet_ai_dispatch_dead_letter_events e join pk on pk.job_id = e.job_id
           where pk.phone_number = '919650000001' and e.event_type = 'DEAD_LETTERED'),
  1, 'exactly one DEAD_LETTERED audit event exists');

select ok((select d.status = 'open' and d.policy_key = 'whatsapp.packet_ai_dispatch.default' and d.attempt_count = 10
                  and d.context->>'dead_letter_class' = 'RETRY_EXHAUSTED'
           from public.dead_letter_entries d join pk on pk.job_id::text = d.source_record_id
           where pk.phone_number = '919650000001' and d.source_table = 'whatsapp_packet_ai_dispatch_jobs'),
  'exhaustion also opens an entry in the platform dead-letter console');

-- a dead-lettered job is never claimable again
update public.whatsapp_packet_ai_dispatch_jobs set next_retry_at = statement_timestamp() - interval '1 day';
select pg_temp.only_claimable((select job_id from pk where phone_number = '919650000001'));
select is((select id from public.claim_whatsapp_packet_ai_dispatch_job(120)), null::uuid,
  'claim never returns a DEAD_LETTERED job, even when its next_retry_at is long past');

-- ------------------------------- 2. deterministic failures stop immediately --
select is(pg_temp.fail_once((select job_id from pk where phone_number = '919650000002'),
  'INTERPRETATION_PACKET_TOO_LARGE', 'INTERPRETATION_PACKET_TOO_LARGE'), true,
  'a deterministic failure is accepted by the retry RPC');
select is((select state || '/' || dead_letter_class || '/' || dead_letter_reason from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000002'),
  'DEAD_LETTERED/DETERMINISTIC/INTERPRETATION_PACKET_TOO_LARGE',
  'INTERPRETATION_PACKET_TOO_LARGE dead-letters on the first occurrence (no 4,934-attempt loop)');
select is((select attempt_count from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000002'),
  1, 'only one attempt was consumed');

-- --------------------------- 3. model-output failures have a smaller budget --
create temporary table schema_claims(n int);
do $$
declare v_job uuid; i int; ok boolean;
begin
  select job_id into v_job from pk where phone_number = '919650000005';
  for i in 1..20 loop
    ok := pg_temp.fail_once(v_job, 'INTERPRETER_INVALID_SCHEMA', 'bad schema');
    exit when ok is null;
    insert into schema_claims values (i);
  end loop;
end $$;
select is((select count(*)::int from schema_claims), 3,
  'invalid model output (a paid call per attempt) is capped at 3 attempts');
select is((select dead_letter_class from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000005'),
  'RETRY_EXHAUSTED', 'the invalid-schema budget terminates as RETRY_EXHAUSTED');

-- ------------------------------ 3b. worker crash loops are bounded too ------
-- A crashing / timing-out worker never reports a failure: its lease expires and
-- the job is re-leased. Each reclaim spends the same budget.
create temporary table crash_claims(n int);
do $$
declare v_job uuid; i int; c public.whatsapp_packet_ai_dispatch_jobs%rowtype;
begin
  select job_id into v_job from pk where phone_number = '919650000008';
  for i in 1..40 loop
    perform pg_temp.only_claimable(v_job);
    update public.whatsapp_packet_ai_dispatch_jobs
    set lease_expires_at = statement_timestamp() - interval '1 second', next_retry_at = statement_timestamp() - interval '1 second'
    where id = v_job and state = 'LEASED';
    select * into c from public.claim_whatsapp_packet_ai_dispatch_job(120);
    exit when c.id is null;
    insert into crash_claims values (i);
  end loop;
end $$;
select is((select count(*)::int from crash_claims), 10,
  'a worker that crashes on every claim is leased at most 10 times');
select is((select state || '/' || dead_letter_class || '/' || dead_letter_reason
           from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000008'),
  'DEAD_LETTERED/RETRY_EXHAUSTED/WORKER_LEASE_EXPIRED_REPEATEDLY', 'the crash loop terminates with an explicit reason');
select is((select count(*)::int from public.whatsapp_packet_ai_dispatch_dead_letter_events e join pk on pk.job_id = e.job_id
           where pk.phone_number = '919650000008' and e.event_type = 'DEAD_LETTERED')
        + (select count(*)::int from public.dead_letter_entries d join pk on pk.job_id::text = d.source_record_id
           where pk.phone_number = '919650000008' and d.status = 'open'),
  2, 'the crash-loop termination wrote exactly one audit event and one console entry');

update public.whatsapp_packet_ai_dispatch_jobs set bounded_retry = false where id = (select job_id from pk where phone_number = '919650000009');
do $$
declare v_job uuid; i int; c public.whatsapp_packet_ai_dispatch_jobs%rowtype;
begin
  select job_id into v_job from pk where phone_number = '919650000009';
  for i in 1..15 loop
    perform pg_temp.only_claimable(v_job);
    update public.whatsapp_packet_ai_dispatch_jobs
    set lease_expires_at = statement_timestamp() - interval '1 second', next_retry_at = statement_timestamp() - interval '1 second'
    where id = v_job and state = 'LEASED';
    select * into c from public.claim_whatsapp_packet_ai_dispatch_job(120);
  end loop;
end $$;
select is((select state from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000009'),
  'LEASED', 'a legacy job keeps its previous crash-reclaim behaviour (no automatic dead-lettering)');
select is((select attempt_count from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000009'),
  15, 'legacy attempt accounting is unchanged');
select is((select retry_budget_used from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000009'),
  0, 'legacy jobs spend no budget');

-- ---- 3c. the deployed worker flags KNOWLEDGE_SNAPSHOT_* as knowledge-authority ----
-- KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE is deterministic, but the worker passes
-- p_knowledge_authority_failure = true for it; bounded jobs must still stop.
select is(pg_temp.fail_once((select job_id from pk where phone_number = '919650000010'),
  'KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE', 'KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE', true), true,
  'the deployed-worker call shape (knowledge flag = true) is accepted');
select is((select state || '/' || dead_letter_class || '/' || dead_letter_reason from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000010'),
  'DEAD_LETTERED/DETERMINISTIC/KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE',
  'an oversized knowledge context dead-letters for a bounded job even with the knowledge flag set');
update public.whatsapp_packet_ai_dispatch_jobs set bounded_retry = false where id = (select job_id from pk where phone_number = '919650000011');
select pg_temp.fail_once((select job_id from pk where phone_number = '919650000011'),
  'KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE', 'KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE', true);
select is((select state from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000011'),
  'BLOCKED_KNOWLEDGE_AUTHORITY', 'a legacy job keeps its previous knowledge-authority behaviour');
select is(pg_temp.fail_once((select job_id from pk where phone_number = '919650000001'), 'X', 'x', true), null::boolean,
  'sanity: a dead-lettered job is not claimable for the knowledge-flag path either');

-- ---------- 4. ambiguous multiple potential orders -> governed human review --
insert into public.whatsapp_communication_cases(packet_id, case_type, status, rule_version)
select packet_id, 'ORDER', 'OPEN', 'test' from pk where phone_number = '919650000003';
create temporary table pre_orders as
  select (select count(*) from public.orders) as orders_n,
         (select count(*) from public.whatsapp_sales_order_drafts) as drafts_n,
         (select count(*) from public.whatsapp_potential_orders) as pos_n;

select is(pg_temp.fail_once((select job_id from pk where phone_number = '919650000003'),
  'CASE_MATERIALIZATION_FAILED',
  'CASE_MATERIALIZATION_FAILED:multiple potential orders are linked to this communication case'), true,
  'the ambiguous-order failure is accepted');
select is((select state || '/' || dead_letter_class || '/' || dead_letter_reason from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000003'),
  'DEAD_LETTERED/HUMAN_REVIEW_REQUIRED/AMBIGUOUS_POTENTIAL_ORDERS',
  'ambiguity terminates as HUMAN_REVIEW_REQUIRED on the first occurrence');
select is((select count(*)::int from public.whatsapp_case_department_tasks t join public.whatsapp_communication_cases c on c.id = t.case_id
           join pk on pk.packet_id = c.packet_id
           where pk.phone_number = '919650000003' and t.task_type = 'AMBIGUOUS_POTENTIAL_ORDER_REVIEW'
             and t.status = 'OPEN' and t.department = 'OPERATIONS'),
  1, 'exactly one OPEN governed OPERATIONS review task exists for the case');
select is((select count(*)::int from public.whatsapp_case_events e join public.whatsapp_communication_cases c on c.id = e.case_id
           join pk on pk.packet_id = c.packet_id
           where pk.phone_number = '919650000003' and e.event_type = 'AMBIGUOUS_POTENTIAL_ORDERS_ROUTED_TO_HUMAN_REVIEW'),
  1, 'the routing is recorded as a case event');
select ok((select (select count(*) from public.orders) = orders_n
              and (select count(*) from public.whatsapp_sales_order_drafts) = drafts_n
              and (select count(*) from public.whatsapp_potential_orders) = pos_n from pre_orders),
  'no order, draft or potential order was created or selected automatically');
select ok((select sales_order_draft_id is null from public.whatsapp_communication_cases c join pk on pk.packet_id = c.packet_id where pk.phone_number = '919650000003'),
  'the case is not bound to any order draft');

select ok((select d.status = 'open' and d.context->>'dead_letter_class' = 'HUMAN_REVIEW_REQUIRED'
           from public.dead_letter_entries d join pk on pk.job_id::text = d.source_record_id
           where pk.phone_number = '919650000003' and d.source_table = 'whatsapp_packet_ai_dispatch_jobs'),
  'the ambiguity dead letter is visible in the platform dead-letter console');

-- budgets are governed data: tightening the policy tightens the bound
update public.retry_policies set max_attempts = 4 where policy_key = 'whatsapp.packet_ai_dispatch.default';
create temporary table tuned_claims(n int);
do $$
declare v_job uuid; i int; ok boolean;
begin
  select job_id into v_job from pk where phone_number = '919650000007';
  for i in 1..20 loop
    ok := pg_temp.fail_once(v_job, 'GEMINI_UNAVAILABLE', 'upstream 503');
    exit when ok is null;
    insert into tuned_claims values (i);
  end loop;
end $$;
update public.retry_policies set max_attempts = 10 where policy_key = 'whatsapp.packet_ai_dispatch.default';
select is((select count(*)::int from tuned_claims), 4, 'the attempt budget is read from the governed retry policy');

-- ------------------------------------ 5. duplicate delivery is idempotent ----
create temporary table dup_claim as
  select * from public.claim_whatsapp_packet_ai_dispatch_job(120) where false;
update public.whatsapp_packet_ai_dispatch_jobs set state = 'QUEUED', next_retry_at = statement_timestamp() - interval '1 second'
where id = (select job_id from pk where phone_number = '919650000006');
select pg_temp.only_claimable((select job_id from pk where phone_number = '919650000006'));
insert into dup_claim select * from public.claim_whatsapp_packet_ai_dispatch_job(120);
select is(public.retry_whatsapp_packet_ai_dispatch_job((select id from dup_claim), (select lease_token from dup_claim),
  (select packet_revision from dup_claim), 'PACKET_EMPTY', 'PACKET_EMPTY', false), true, 'first delivery dead-letters the job');
select is(public.retry_whatsapp_packet_ai_dispatch_job((select id from dup_claim), (select lease_token from dup_claim),
  (select packet_revision from dup_claim), 'PACKET_EMPTY', 'PACKET_EMPTY', false), false,
  'a duplicate delivery of the same failure is a no-op (lease already released)');
select is((select count(*)::int from public.whatsapp_packet_ai_dispatch_dead_letter_events where job_id = (select id from dup_claim)),
  1, 'the duplicate delivery wrote no second audit event');
select throws_ok($$insert into public.whatsapp_packet_ai_dispatch_dead_letter_events(job_id, packet_id, event_type, idempotency_key)
  select job_id, packet_id, 'DEAD_LETTERED', 'dead-letter:' || job_id::text || ':attempt:1' from pk where phone_number = '919650000006'$$,
  '23505', null, 'the audit idempotency key is unique');
select is(public.retry_whatsapp_packet_ai_dispatch_job((select id from dup_claim), gen_random_uuid(),
  (select packet_revision from dup_claim), 'X', 'x', false), false,
  'a wrong lease token can never terminate or reschedule a job');

-- -------------------- 6. historical (legacy) jobs keep prior behaviour --------
create temporary table legacy_job as select job_id from pk where phone_number = '919650000004';
update public.whatsapp_packet_ai_dispatch_jobs set bounded_retry = false where id = (select job_id from legacy_job);
do $$
declare v_job uuid; i int;
begin
  select job_id into v_job from legacy_job;
  for i in 1..40 loop
    perform pg_temp.fail_once(v_job, 'CASE_MATERIALIZATION_FAILED',
      'CASE_MATERIALIZATION_FAILED:multiple potential orders are linked to this communication case');
  end loop;
end $$;
select is((select state from public.whatsapp_packet_ai_dispatch_jobs where id = (select job_id from legacy_job)),
  'RETRY', 'a pre-existing job is NOT auto-dead-lettered by the migration or by new failures');
select is((select attempt_count from public.whatsapp_packet_ai_dispatch_jobs where id = (select job_id from legacy_job)),
  40, 'legacy attempt accounting is unchanged');
select ok((select dead_lettered_at is null and dead_letter_class is null from public.whatsapp_packet_ai_dispatch_jobs where id = (select job_id from legacy_job)),
  'no terminal markers are written to a legacy job');

-- ----------------------------- 7. operator RPCs: authority, reversibility ----
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

select is(public.dead_letter_whatsapp_packet_ai_dispatch_job(
  (select job_id from legacy_job), 'operator-approved quarantine of historical loop',
  '86500000-0000-0000-0000-0000000000f1', 'case-1'), true, 'an operator can explicitly dead-letter a legacy job');
select is((select state || '/' || dead_letter_class from public.whatsapp_packet_ai_dispatch_jobs where id = (select job_id from legacy_job)),
  'DEAD_LETTERED/OPERATOR_QUARANTINE', 'operator quarantine is classified distinctly');
select is(public.dead_letter_whatsapp_packet_ai_dispatch_job(
  (select job_id from legacy_job), 'operator-approved quarantine of historical loop',
  '86500000-0000-0000-0000-0000000000f1', 'case-1'), true, 'replaying the same operator request is idempotent');
select is((select count(*)::int from public.whatsapp_packet_ai_dispatch_dead_letter_events
           where job_id = (select job_id from legacy_job) and event_type = 'OPERATOR_DEAD_LETTERED'),
  1, 'the replay wrote no second event');
select is(public.requeue_whatsapp_packet_ai_dispatch_job(
  (select job_id from legacy_job), 'ambiguity resolved by operator review',
  '86500000-0000-0000-0000-0000000000f1', 'case-2'), true, 'the operator quarantine is reversible by requeue');
select is((select state || '/' || retry_budget_used::text || '/' || bounded_retry::text
           from public.whatsapp_packet_ai_dispatch_jobs where id = (select job_id from legacy_job)),
  'QUEUED/0/true', 'a requeued job is QUEUED with a fresh budget and is now bounded');
select ok((select dead_lettered_at is null and dead_letter_class is null and dead_letter_reason is null
           from public.whatsapp_packet_ai_dispatch_jobs where id = (select job_id from legacy_job)),
  'requeue clears the terminal markers (audit history is retained in the event log)');
select is(public.requeue_whatsapp_packet_ai_dispatch_job(
  (select job_id from legacy_job), 'ambiguity resolved by operator review',
  '86500000-0000-0000-0000-0000000000f1', 'case-2'), true, 'requeue replay is idempotent');
select is(public.dead_letter_whatsapp_packet_ai_dispatch_job(
  gen_random_uuid(), 'operator-approved quarantine of nothing', '86500000-0000-0000-0000-0000000000f1', 'case-3'),
  false, 'dead-lettering an unknown job returns false');
select throws_ok($$select public.dead_letter_whatsapp_packet_ai_dispatch_job(gen_random_uuid(), 'bad', null, 'k')$$,
  '22023', null, 'missing actor / short reason is rejected');

-- ---- 7b. a legacy job crash-looping in LEASED is visible and stoppable --------
select is(public.dead_letter_whatsapp_packet_ai_dispatch_job(
  (select job_id from pk where phone_number = '919650000009'), 'live lease must not be stolen',
  '86500000-0000-0000-0000-0000000000f1', 'leased-live'), false,
  'the operator RPC refuses a LEASED job whose lease is still live');
select ok(exists(select 1 from public.whatsapp_packet_ai_dispatch_exceptions_v v join pk on pk.job_id = v.job_id
                 where pk.phone_number = '919650000009' and v.state = 'LEASED' and v.still_retrying),
  'the exceptions view surfaces a legacy job crash-looping in LEASED past 10 attempts');
update public.whatsapp_packet_ai_dispatch_jobs set lease_expires_at = statement_timestamp() - interval '1 second'
where id = (select job_id from pk where phone_number = '919650000009');
select is(public.dead_letter_whatsapp_packet_ai_dispatch_job(
  (select job_id from pk where phone_number = '919650000009'), 'operator stops the legacy crash loop',
  '86500000-0000-0000-0000-0000000000f1', 'leased-expired'), true,
  'the operator RPC dead-letters a LEASED job once its lease has expired');
select is((select state || '/' || dead_letter_class from public.whatsapp_packet_ai_dispatch_jobs j join pk on pk.job_id = j.id where pk.phone_number = '919650000009'),
  'DEAD_LETTERED/OPERATOR_QUARANTINE', 'the crash loop is terminated and classified as an operator quarantine');

-- --------------------------------------------- 8. revival on a new revision ---
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id, status, message_timestamp, created_at, packet_id
) values (
  '86500000-0000-0000-0000-000000000199', '86500000-0000-0000-0000-000000000002', 'inbound', 'text', 'follow-up',
  'click2api', 'bounded-revive', 'received', '2026-10-22 11:00:00', '2026-10-22 11:00:00',
  (select packet_id from pk where phone_number = '919650000002')
);
select is((select state || '/' || retry_budget_used::text || '/' || bounded_retry::text from public.whatsapp_packet_ai_dispatch_jobs
           where id = (select job_id from pk where phone_number = '919650000002')),
  'QUEUED/0/true', 'new inbound content revives a dead-lettered job via the existing enqueue path with a fresh budget');
select is((select d.status from public.dead_letter_entries d join pk on pk.job_id::text = d.source_record_id
           where pk.phone_number = '919650000002' and d.source_table = 'whatsapp_packet_ai_dispatch_jobs'),
  'requeued', 'revival closes the platform dead-letter entry as requeued');
select is((select count(*)::int from public.whatsapp_packet_ai_dispatch_dead_letter_events
           where job_id = (select job_id from pk where phone_number = '919650000002') and event_type = 'REVIVED_BY_NEW_REVISION'),
  1, 'the revival is audited');

-- --------------------------------------------- 9. audit + shape protections ---
select throws_ok($$update public.whatsapp_packet_ai_dispatch_dead_letter_events set reason = 'tamper'$$,
  '42501', null, 'the dead-letter event log is append-only (update)');
select throws_ok($$delete from public.whatsapp_packet_ai_dispatch_dead_letter_events$$,
  '42501', null, 'the dead-letter event log is append-only (delete)');
select throws_ok($$update public.whatsapp_packet_ai_dispatch_jobs set state = 'DEAD_LETTERED'
  where id = (select job_id from legacy_job)$$,
  '23514', null, 'DEAD_LETTERED without class, reason and timestamp violates the shape constraint');

-- ------------------------------------------- 10. visibility and privileges ---
select ok((select count(*) from public.whatsapp_packet_ai_dispatch_exceptions_v) >= 4,
  'service role sees dead-lettered jobs in the operator exceptions view');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"86500000-0000-0000-0000-0000000000aa"}', true);
select throws_ok($$select count(*) from public.whatsapp_packet_ai_dispatch_exceptions_v$$, '42501', null,
  'authenticated users cannot read the service-role exceptions view');
select is((select count(*)::int from public.whatsapp_packet_ai_dispatch_dead_letter_events), 0,
  'an authenticated user without WhatsApp inbox permission sees no dead-letter events (RLS)');
select throws_ok($$select public.dead_letter_whatsapp_packet_ai_dispatch_job(gen_random_uuid(), 'authenticated attempt', gen_random_uuid(), 'k')$$,
  '42501', null, 'authenticated users cannot execute the operator dead-letter RPC');
select throws_ok($$select public.requeue_whatsapp_packet_ai_dispatch_job(gen_random_uuid(), 'authenticated attempt', gen_random_uuid(), 'k')$$,
  '42501', null, 'authenticated users cannot execute the operator requeue RPC');
reset role;
select ok(not has_function_privilege('anon', 'public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)', 'execute')
      and not has_function_privilege('authenticated', 'public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)', 'execute')
      and has_function_privilege('service_role', 'public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)', 'execute'),
  'the retry RPC remains service-role only');
select ok(not has_function_privilege('anon', 'public.whatsapp_packet_ai_dispatch_dead_letter_v1(uuid,text,text,text,text,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.whatsapp_packet_ai_dispatch_dead_letter_v1(uuid,text,text,text,text,text)', 'execute')
      and not has_function_privilege('service_role', 'public.whatsapp_packet_ai_dispatch_dead_letter_v1(uuid,text,text,text,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.prevent_whatsapp_packet_ai_dispatch_dead_letter_event_mutation()', 'execute')
      and not has_function_privilege('authenticated', 'public.prevent_whatsapp_packet_ai_dispatch_dead_letter_event_mutation()', 'execute'),
  'the internal dead-letter helper and the audit guard trigger function are not callable by API roles');
select ok(not has_table_privilege('anon', 'public.whatsapp_packet_ai_dispatch_dead_letter_events', 'select'),
  'anon has no access to the dead-letter event log');

select * from finish();
rollback;
