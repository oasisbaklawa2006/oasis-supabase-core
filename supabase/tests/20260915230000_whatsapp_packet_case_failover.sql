begin;
-- Regression coverage for CERT-WA-001 / 20260915230000_whatsapp_packet_case_failover.sql.

select plan(14);

select has_function(
  'public',
  'whatsapp_materialize_stale_packet_case_failover',
  array['integer','integer'],
  'stale-packet failover RPC exists'
);

select ok(
  not has_function_privilege('anon', 'public.whatsapp_materialize_stale_packet_case_failover(integer,integer)', 'execute'),
  'anon cannot execute stale-packet failover'
);
select ok(
  not has_function_privilege('authenticated', 'public.whatsapp_materialize_stale_packet_case_failover(integer,integer)', 'execute'),
  'authenticated clients cannot execute stale-packet failover'
);
select ok(
  has_function_privilege('service_role', 'public.whatsapp_materialize_stale_packet_case_failover(integer,integer)', 'execute'),
  'service role may execute stale-packet failover'
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('91511000-0000-0000-0000-000000000001', '919151100001', 'CERT-WA-001 contact');

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '91511000-0000-0000-0000-000000000002',
  '91511000-0000-0000-0000-000000000001',
  'inbound', 'text', 'cert stranded packet', 'click2api', 'cert-wa-001-message',
  'received', statement_timestamp() - interval '20 minutes', statement_timestamp() - interval '20 minutes'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '91511000-0000-0000-0000-000000000001',
    array['91511000-0000-0000-0000-000000000002'::uuid],
    300
  )$$,
  'fixture stitches and atomically creates its durable AI dispatch job'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id=(select packet_id from public.whatsapp_messages where id='91511000-0000-0000-0000-000000000002')
     and execution_kind='PACKET'),
  'QUEUED',
  'stranded fixture begins with a queued AI dispatch job'
);

select lives_ok(
  $$select public.whatsapp_run_system_reconciliation(
    statement_timestamp() - interval '25 minutes',
    statement_timestamp() - interval '15 minutes',
    'CERT_WA_001',
    statement_timestamp() + interval '1 hour',
    'cert-wa-001-pre-failover'
  )$$,
  'reconciliation records the packet-without-case condition'
);

select is(
  (select count(*)::integer
   from public.whatsapp_reconciliation_exceptions e
   where e.exception_type='PACKET_WITHOUT_CASE'
     and e.business_object_id=(select packet_id from public.whatsapp_messages where id='91511000-0000-0000-0000-000000000002')
     and e.resolved_at is null),
  1,
  'reconciliation exposes the stranded packet before failover'
);

select is(
  (public.whatsapp_materialize_stale_packet_case_failover(600, 10)->>'cases_created')::integer,
  1,
  'failover materializes exactly one governed human-review case'
);

select results_eq(
  $$select case_type, status, accountability_status, accountable_team, rule_version
    from public.whatsapp_communication_cases
    where packet_id=(select packet_id from public.whatsapp_messages where id='91511000-0000-0000-0000-000000000002')$$,
  $$values ('UNCLASSIFIED'::text,'NEEDS_IDENTITY'::text,'UNASSIGNED'::text,'OPERATIONS'::text,'packet-ai-failover-v1'::text)$$,
  'fallback is explicitly non-commercial and routed to governed manual triage'
);

select is(
  (select count(*)::integer
   from public.whatsapp_case_events ce
   join public.whatsapp_communication_cases c on c.id=ce.case_id
   where c.packet_id=(select packet_id from public.whatsapp_messages where id='91511000-0000-0000-0000-000000000002')
     and ce.event_type='PACKET_AI_FAILOVER_MATERIALIZED'),
  1,
  'failover writes an auditable case event'
);

select is(
  (select count(*)::integer
   from public.whatsapp_reconciliation_exceptions e
   where e.exception_type='PACKET_WITHOUT_CASE'
     and e.business_object_id=(select packet_id from public.whatsapp_messages where id='91511000-0000-0000-0000-000000000002')
     and e.resolved_at is null),
  0,
  'prior packet-without-case exception is resolved after fallback case creation'
);

select is(
  (public.whatsapp_materialize_stale_packet_case_failover(600, 10)->>'cases_created')::integer,
  0,
  'failover replay is idempotent and does not duplicate the case'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id=(select packet_id from public.whatsapp_messages where id='91511000-0000-0000-0000-000000000002')
     and execution_kind='PACKET'),
  'QUEUED',
  'failover does not forge AI completion; the durable job remains recoverable for later enrichment'
);

select * from finish();
rollback;
