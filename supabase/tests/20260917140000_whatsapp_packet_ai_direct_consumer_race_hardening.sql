-- Contract coverage for migration: 20260917140000_whatsapp_packet_ai_direct_consumer_race_hardening.sql
-- Gate 6 keeps the legacy packet-scoped claim retired and proves the canonical
-- claim path is race-safe under two genuinely concurrent PostgreSQL sessions.
create extension if not exists dblink with schema extensions;

begin;
select plan(6);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86511000-0000-0000-0000-000000000001', '919651100001', 'Direct path retired contact');
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '86511000-0000-0000-0000-000000000011', '86511000-0000-0000-0000-000000000001',
  'inbound', 'text', 'direct path retired', 'click2api', 'direct-retired-a', 'received',
  statement_timestamp(), statement_timestamp()
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86511000-0000-0000-0000-000000000001',
    array['86511000-0000-0000-0000-000000000011'::uuid], 300)$$,
  'fixture packet exists for direct-path retirement check'
);

select is(
  (select public.claim_whatsapp_packet_ai_dispatch_job_for_packet(
    (select packet_id from public.whatsapp_messages where id = '86511000-0000-0000-0000-000000000011'),
    120
  )),
  null::public.whatsapp_packet_ai_dispatch_jobs,
  'Gate 6 retires legacy direct packet-scoped dispatch claim'
);

-- Build one committed remote fixture because dblink sessions cannot see this
-- test transaction's uncommitted rows. The ids are unique to this test and are
-- cleaned before finish().
select extensions.dblink_connect('race_setup', 'dbname=' || current_database());
select extensions.dblink_exec(
  'race_setup',
  $remote$
    insert into public.whatsapp_contacts(id, phone_number, customer_name)
    values ('86511400-0000-0000-0000-000000000001', '919651140001', 'Canonical claim race contact');
  $remote$
);
select extensions.dblink_exec(
  'race_setup',
  $remote$
    insert into public.whatsapp_message_packets(
      id, contact_id, stitched_content, fragment_count,
      first_message_at, last_message_at, status, ai_dispatch_revision
    ) values (
      '86511400-0000-0000-0000-000000000010',
      '86511400-0000-0000-0000-000000000001',
      '{}'::jsonb, 1, statement_timestamp(), statement_timestamp(), 'ready', 1
    );
  $remote$
);
select extensions.dblink_exec(
  'race_setup',
  $remote$
    insert into public.whatsapp_packet_ai_dispatch_jobs(
      id, packet_id, packet_revision, logical_dispatch_key, state,
      attempt_count, next_retry_at, execution_kind
    ) values (
      '86511400-0000-0000-0000-000000000020',
      '86511400-0000-0000-0000-000000000010',
      1, 'race:canonical-claim:86511400', 'QUEUED',
      0, statement_timestamp(), 'PACKET'
    );
  $remote$
);

select extensions.dblink_connect('race_a', 'dbname=' || current_database());
select extensions.dblink_connect('race_b', 'dbname=' || current_database());

-- Session A claims the only eligible job and deliberately holds the statement
-- open for two seconds. The row lock therefore remains live while session B
-- invokes the same canonical claim function.
select ok(
  extensions.dblink_send_query(
    'race_a',
    $remote$
      with claimed as materialized (
        select id::text as id
        from public.claim_whatsapp_packet_ai_dispatch_job(120)
      ),
      held as materialized (
        select pg_sleep(2) from claimed
      )
      select claimed.id from claimed cross join held
    $remote$
  ) = 1,
  'session A starts an asynchronous canonical claim and holds its row lock'
);

select pg_sleep(0.25);

select is(
  (
    select id
    from extensions.dblink(
      'race_b',
      'select id::text from public.claim_whatsapp_packet_ai_dispatch_job(120)'
    ) as competing(id text)
    limit 1
  ),
  null::text,
  'session B skips the locked dispatch row and cannot claim the same job'
);

select is(
  (
    select id
    from extensions.dblink_get_result('race_a') as winner(id text)
    limit 1
  ),
  '86511400-0000-0000-0000-000000000020'::text,
  'session A is the sole concurrent claimant'
);

select ok(
  (
    select state = 'LEASED' and attempt_count = 1 and lease_token is not null
    from public.whatsapp_packet_ai_dispatch_jobs
    where id = '86511400-0000-0000-0000-000000000020'
  ),
  'concurrent race leaves exactly one lease/attempt on the dispatch job'
);

select extensions.dblink_exec(
  'race_setup',
  $$delete from public.whatsapp_packet_ai_dispatch_jobs where id='86511400-0000-0000-0000-000000000020'$$
);
select extensions.dblink_exec(
  'race_setup',
  $$delete from public.whatsapp_message_packets where id='86511400-0000-0000-0000-000000000010'$$
);
select extensions.dblink_exec(
  'race_setup',
  $$delete from public.whatsapp_contacts where id='86511400-0000-0000-0000-000000000001'$$
);
select extensions.dblink_disconnect('race_a');
select extensions.dblink_disconnect('race_b');
select extensions.dblink_disconnect('race_setup');

select * from finish();
rollback;
