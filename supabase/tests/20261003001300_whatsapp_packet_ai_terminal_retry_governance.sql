begin;
-- Contract coverage for 20261003001300_whatsapp_packet_ai_terminal_retry_governance.sql.
select plan(14);

select ok(
  (select pg_get_constraintdef(oid)
   from pg_constraint
   where conrelid='public.whatsapp_packet_ai_dispatch_jobs'::regclass
     and conname='whatsapp_packet_ai_dispatch_jobs_state_check')
  like '%BLOCKED_PERMANENT%',
  'packet AI dispatch state contract includes terminal BLOCKED_PERMANENT'
);

select isnt_empty(
  $$select 1
    from pg_proc
    where oid='public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)'::regprocedure
      and pg_get_functiondef(oid) like '%INTERPRETATION_PACKET_TOO_LARGE%'
      and pg_get_functiondef(oid) like '%BLOCKED_PERMANENT%'$$,
  'retry authority explicitly terminalizes deterministic oversize packets'
);

insert into public.whatsapp_contacts(id,phone_number,customer_name)
values ('87200000-0000-0000-0000-000000000001','919720000001','Terminal retry contact');

insert into public.whatsapp_messages(
  id,contact_id,direction,message_type,content,provider,provider_message_id,status,message_timestamp,created_at
) values (
  '87200000-0000-0000-0000-000000000011',
  '87200000-0000-0000-0000-000000000001',
  'inbound','text','oversize retry contract fixture','click2api',
  'terminal-retry-a','received',
  '2026-10-01 14:30:00+00','2026-10-01 14:30:00+00'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '87200000-0000-0000-0000-000000000001',
    array['87200000-0000-0000-0000-000000000011'::uuid],
    300
  )$$,
  'fixture creates packet and durable dispatch job'
);

-- Deterministic oversize failure terminalizes immediately.
update public.whatsapp_packet_ai_dispatch_jobs
set state='LEASED',
    attempt_count=1,
    claimed_at=statement_timestamp(),
    last_attempt_at=statement_timestamp(),
    lease_expires_at=statement_timestamp()+interval '120 seconds',
    lease_token='87200000-0000-0000-0000-000000000101'::uuid
where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
  and execution_kind='PACKET';

select ok(
  public.retry_whatsapp_packet_ai_dispatch_job(
    (select id from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    '87200000-0000-0000-0000-000000000101'::uuid,
    (select packet_revision from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    'INTERPRETATION_PACKET_TOO_LARGE',
    'INTERPRETATION_PACKET_TOO_LARGE',
    false
  ),
  'oversize failure is accepted for disposition'
);
select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
     and execution_kind='PACKET'),
  'BLOCKED_PERMANENT',
  'oversize packet becomes terminal instead of retrying forever'
);
select is(
  (select next_retry_at::text from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
     and execution_kind='PACKET'),
  'infinity',
  'terminal oversize packet is non-claimable by retry time'
);

select is(
  (select count(*)::integer
   from public.whatsapp_communication_cases c
   where c.packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
     and c.next_action like 'Manual review required: packet AI processing blocked (%'),
  1,
  'terminal packet AI failure is surfaced as one governed Operations human-review case'
);
select is(
  (select count(*)::integer
   from public.whatsapp_case_events e
   join public.whatsapp_communication_cases c on c.id=e.case_id
   where c.packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
     and e.event_type='PACKET_AI_TERMINAL_BLOCKED'
     and e.metadata->>'error_code'='INTERPRETATION_PACKET_TOO_LARGE'),
  1,
  'terminal packet AI failure appends one auditable case event'
);

-- Transient failures remain retryable below the budget.
update public.whatsapp_packet_ai_dispatch_jobs
set state='LEASED',
    attempt_count=2,
    claimed_at=statement_timestamp(),
    last_attempt_at=statement_timestamp(),
    lease_expires_at=statement_timestamp()+interval '120 seconds',
    lease_token='87200000-0000-0000-0000-000000000102'::uuid
where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
  and execution_kind='PACKET';

select ok(
  public.retry_whatsapp_packet_ai_dispatch_job(
    (select id from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    '87200000-0000-0000-0000-000000000102'::uuid,
    (select packet_revision from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    'AI_TIMEOUT',
    'transient timeout',
    false
  ),
  'transient failure below retry budget is accepted'
);
select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
     and execution_kind='PACKET'),
  'RETRY',
  'transient failure below attempt five remains retryable'
);

-- Fifth claimed attempt terminalizes non-knowledge failures.
update public.whatsapp_packet_ai_dispatch_jobs
set state='LEASED',
    attempt_count=5,
    claimed_at=statement_timestamp(),
    last_attempt_at=statement_timestamp(),
    lease_expires_at=statement_timestamp()+interval '120 seconds',
    lease_token='87200000-0000-0000-0000-000000000103'::uuid
where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
  and execution_kind='PACKET';

select ok(
  public.retry_whatsapp_packet_ai_dispatch_job(
    (select id from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    '87200000-0000-0000-0000-000000000103'::uuid,
    (select packet_revision from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    'AI_TIMEOUT',
    'fifth failed attempt',
    false
  ),
  'fifth non-knowledge failure is accepted for terminal disposition'
);
select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
     and execution_kind='PACKET'),
  'BLOCKED_PERMANENT',
  'fifth non-knowledge failure becomes terminal'
);

-- Governed knowledge blocks retain the existing recoverable state.
update public.whatsapp_packet_ai_dispatch_jobs
set state='LEASED',
    attempt_count=7,
    claimed_at=statement_timestamp(),
    last_attempt_at=statement_timestamp(),
    lease_expires_at=statement_timestamp()+interval '120 seconds',
    lease_token='87200000-0000-0000-0000-000000000104'::uuid
where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
  and execution_kind='PACKET';

select ok(
  public.retry_whatsapp_packet_ai_dispatch_job(
    (select id from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    '87200000-0000-0000-0000-000000000104'::uuid,
    (select packet_revision from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    'KNOWLEDGE_SNAPSHOT_NOT_ACTIVELY_GOVERNED',
    'knowledge authority unavailable',
    true
  ),
  'knowledge authority failure preserves recoverable disposition'
);
select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id=(select packet_id from public.whatsapp_messages where id='87200000-0000-0000-0000-000000000011')
     and execution_kind='PACKET'),
  'BLOCKED_KNOWLEDGE_AUTHORITY',
  'knowledge authority remains a distinct recoverable block'
);

select * from finish();
rollback;
