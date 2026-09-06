-- Contract and behavioral coverage for Point 21 shared notification infrastructure.
-- Schema authority: squashed baseline 20260723161256 + archived 20260723153000.
begin;

select plan(32);

select has_function(
  'public',
  'enqueue_notification_v1',
  array['text','text','text','text','text','text','text','text','uuid','integer','timestamptz'],
  'enqueue_notification_v1 canonical writer exists'
);

select has_function(
  'public',
  'claim_notification_batch_v1',
  array['text','integer','integer'],
  'claim_notification_batch_v1 leased batch claim exists'
);

select has_function(
  'public',
  'complete_notification_v1',
  array['uuid','text','text'],
  'complete_notification_v1 delivery acknowledgement exists'
);

select has_function(
  'public',
  'fail_notification_v1',
  array['uuid','text','text','integer'],
  'fail_notification_v1 retry or terminal failure transition exists'
);

insert into public.users (id, role) values
  ('a0210000-0000-0000-0000-000000000001', 'HOD_ARABIC'),
  ('a0210000-0000-0000-0000-000000000002', 'B2B_BUYER');

-- Anonymous enqueue is denied.
select ok(
  not has_function_privilege(
    'anon',
    'public.enqueue_notification_v1(text,text,text,text,text,text,text,text,uuid,integer,timestamptz)',
    'EXECUTE'
  ),
  'anon cannot execute enqueue_notification_v1'
);

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a0210000-0000-0000-0000-000000000002';

select throws_ok(
  $$select public.enqueue_notification_v1(
    'point21_contract_probe', 'account.activation', 'email', 'Activation probe',
    'point21-nonstaff-idem', 'buyer@example.com'
  )$$,
  'internal staff or service role required',
  'non-staff authenticated callers cannot enqueue notifications'
);

set local request.jwt.claim.sub = 'a0210000-0000-0000-0000-000000000001';

select lives_ok(
  $$select public.enqueue_notification_v1(
    'point21_contract_probe', 'account.activation', 'email', 'Activation probe',
    'point21-staff-idem', 'staff@example.com', null, 'normal',
    null, 5, timestamptz '2026-07-23 12:00:00+00'
  )$$,
  'internal staff can enqueue a governed notification'
);

select is(
  public.enqueue_notification_v1(
    'point21_contract_probe', 'account.activation', 'email', 'Activation probe',
    'point21-staff-idem', 'staff@example.com'
  ),
  (select id from public.notification_outbox where source_application = 'point21_contract_probe' and idempotency_key = 'point21-staff-idem'),
  'same idempotency key and payload replays the original notification id'
);

select is(
  (select count(*)::bigint from public.notification_outbox where source_application = 'point21_contract_probe' and idempotency_key = 'point21-staff-idem'),
  1::bigint,
  'idempotent replay does not insert a duplicate row'
);

select throws_ok(
  $$select public.enqueue_notification_v1(
    'point21_contract_probe', 'account.activation', 'email', 'Changed body',
    'point21-staff-idem', 'staff@example.com'
  )$$,
  'idempotency key conflict',
  'same idempotency key with a different payload is rejected'
);

select is(
  (select source_application from public.notification_outbox where idempotency_key = 'point21-staff-idem'),
  'point21_contract_probe',
  'enqueued notification records source_application'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.claim_notification_batch_v1(text,integer,integer)',
    'EXECUTE'
  ),
  'authenticated cannot execute claim_notification_batch_v1'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.claim_notification_batch_v1(text,integer,integer)',
    'EXECUTE'
  ),
  'service_role can execute claim_notification_batch_v1'
);

reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
select set_config('request.jwt.claim.role', 'service_role', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;

select lives_ok(
  $$select public.enqueue_notification_v1(
    'point21_contract_probe', 'order.followup', 'whatsapp', 'Follow-up probe',
    'point21-worker-idem', null, '+919999999999', 'high', null, 5, now()
  )$$,
  'service_role can enqueue notifications'
);

select is(
  (select status from public.notification_outbox where idempotency_key = 'point21-worker-idem'),
  'pending',
  'new notification starts in pending status'
);

select isnt_empty(
  $$select 1 from public.claim_notification_batch_v1('point21-worker-1', 10, 120) where idempotency_key = 'point21-worker-idem'$$,
  'due notification can be claimed once under a worker lease'
);

select is(
  (select status from public.notification_outbox where idempotency_key = 'point21-worker-idem'),
  'processing',
  'claimed notification enters processing status'
);

select is(
  (select locked_by from public.notification_outbox where idempotency_key = 'point21-worker-idem'),
  'point21-worker-1',
  'claimed notification records the worker lease owner'
);

select lives_ok(
  $$select public.complete_notification_v1(
    (select id from public.notification_outbox where idempotency_key = 'point21-worker-idem'),
    'point21-worker-1',
    'provider-point21-1'
  )$$,
  'worker can acknowledge successful delivery'
);

select is(
  (select status from public.notification_outbox where idempotency_key = 'point21-worker-idem'),
  'sent',
  'successful completion records sent status'
);

select is(
  (select provider_message_id from public.notification_outbox where idempotency_key = 'point21-worker-idem'),
  'provider-point21-1',
  'successful completion records provider_message_id'
);

select lives_ok(
  $$select public.enqueue_notification_v1(
    'point21_contract_probe', 'order.retry', 'email', 'Retry probe',
    'point21-retry-idem', 'retry@example.com', null, 'normal', null, 5, now()
  )$$,
  'service_role can enqueue a retry probe notification'
);

select isnt_empty(
  $$select 1 from public.claim_notification_batch_v1('point21-worker-2', 10, 120) where idempotency_key = 'point21-retry-idem'$$,
  'retry probe notification can be claimed'
);

select is(
  public.fail_notification_v1(
    (select id from public.notification_outbox where idempotency_key = 'point21-retry-idem'),
    'point21-worker-2',
    'transient provider timeout',
    30
  ),
  'retry',
  'first failure enters retry status'
);

update public.notification_outbox
set next_attempt_at = now() - interval '1 second'
where idempotency_key = 'point21-retry-idem';

select isnt_empty(
  $$select 1 from public.claim_notification_batch_v1('point21-worker-2', 10, 120) where idempotency_key = 'point21-retry-idem'$$,
  'retry notification can be reclaimed after backoff'
);

select lives_ok(
  $$select public.enqueue_notification_v1(
    'point21_contract_probe', 'order.terminal', 'email', 'Terminal probe',
    'point21-terminal-idem', 'terminal@example.com', null, 'normal', null, 1, now()
  )$$,
  'service_role can enqueue a terminal-failure probe notification'
);

select isnt_empty(
  $$select 1 from public.claim_notification_batch_v1('point21-worker-3', 10, 120) where idempotency_key = 'point21-terminal-idem'$$,
  'terminal probe notification can be claimed'
);

select is(
  public.fail_notification_v1(
    (select id from public.notification_outbox where idempotency_key = 'point21-terminal-idem'),
    'point21-worker-3',
    'provider rejected permanently'
  ),
  'failed',
  'exhausted attempts transition to failed status'
);

select isnt_empty(
  $$select 1
    from public.dead_letter_entries
   where source_application = 'point21_contract_probe'
     and source_table = 'notification_outbox'
     and idempotency_key = 'point21-terminal-idem'$$,
  'terminal failure records a dead-letter entry'
);

select throws_ok(
  $$select public.complete_notification_v1(
    (select id from public.notification_outbox where idempotency_key = 'point21-retry-idem'),
    'point21-worker-wrong',
    'provider-should-not-apply'
  )$$,
  'notification lease not owned',
  'complete rejects a worker that does not own the lease'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.notification_outbox'::regclass),
  'notification_outbox row level security is enabled'
);

select ok(
  exists(
    select 1
    from pg_class idx
    join pg_namespace ns on ns.oid = idx.relnamespace
    join pg_index i on i.indexrelid = idx.oid
    join pg_class tbl on tbl.oid = i.indrelid
    where ns.nspname = 'public'
      and idx.relname = 'notification_outbox_source_idempotency_uidx'
      and tbl.relname = 'notification_outbox'
      and i.indisunique
  ),
  'source-scoped idempotency index is unique on source_application and idempotency_key'
);

select * from finish();
rollback;
