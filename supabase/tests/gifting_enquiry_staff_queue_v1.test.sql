-- Gifting enquiry staff queue contract coverage for
-- 20261118220000_gifting_enquiry_staff_queue_v1.sql (Central #677).

begin;

select plan(28);

-- ---------------------------------------------------------------------------
-- Fixtures (synthetic)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('93000000-0000-0000-0000-000000000001', 'gq-admin@example.invalid'),
  ('93000000-0000-0000-0000-000000000002', 'gq-super@example.invalid'),
  ('93000000-0000-0000-0000-000000000003', 'gq-inactive-admin@example.invalid'),
  ('93000000-0000-0000-0000-000000000004', 'gq-support@example.invalid');
insert into public.users (id, role, email, is_active) values
  ('93000000-0000-0000-0000-000000000001', 'admin', 'gq-admin@example.invalid', true),
  ('93000000-0000-0000-0000-000000000002', 'super_admin', 'gq-super@example.invalid', true),
  ('93000000-0000-0000-0000-000000000003', 'admin', 'gq-inactive-admin@example.invalid', false),
  ('93000000-0000-0000-0000-000000000004', 'support_executive', 'gq-support@example.invalid', true);

insert into public.connect_consumers (id, consumer_key, consumer_type, environment)
values ('93100000-0000-0000-0000-000000000001', 'gq-consumer', 'b2c_website', 'staging');

insert into public.gifting_enquiries (
  id, consumer_id, environment, source_lead_id, payload_hash, kind, email, name, message, source,
  marketing_consent, status, first_received_at
) values
  ('93200000-0000-0000-0000-000000000001', '93100000-0000-0000-0000-000000000001', 'staging', gen_random_uuid(), 'h1', 'corporate', 'a@example.invalid', 'A', 'm1', 'gq', false, 'received', now() - interval '3 hours'),
  ('93200000-0000-0000-0000-000000000002', '93100000-0000-0000-0000-000000000001', 'staging', gen_random_uuid(), 'h2', 'wedding',   'b@example.invalid', 'B', 'm2', 'gq', true,  'received', now() - interval '2 hours'),
  ('93200000-0000-0000-0000-000000000003', '93100000-0000-0000-0000-000000000001', 'staging', gen_random_uuid(), 'h3', 'contact',   'c@example.invalid', 'C', 'm3', 'gq', false, 'closed',   now() - interval '1 hour');

-- ---------------------------------------------------------------------------
-- Privilege contract
-- ---------------------------------------------------------------------------
select ok(
  not has_table_privilege('authenticated', 'public.gifting_enquiries', 'SELECT')
  and not has_table_privilege('authenticated', 'public.gifting_enquiries', 'UPDATE')
  and not has_table_privilege('anon', 'public.gifting_enquiries', 'SELECT'),
  'staff and anon have no direct table access; the RPCs are the only path'
);
select ok(
  has_function_privilege('authenticated', 'public.gifting_enquiry_queue_list_v1(text,integer,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.gifting_enquiry_queue_list_v1(text,integer,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.gifting_enquiry_queue_set_status_v1(uuid,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.gifting_enquiry_queue_set_status_v1(uuid,text)', 'EXECUTE'),
  'queue RPCs are callable by authenticated (runtime-gated) and never by anon'
);
select ok(
  not has_function_privilege('authenticated', 'public.gifting_enquiry_queue_authorized()', 'EXECUTE'),
  'the authorization helper is not directly callable by authenticated'
);
select ok(
  (select bool_and(prosecdef and proconfig @> array['search_path=pg_catalog, public'])
     from pg_proc
    where oid in (
      'public.gifting_enquiry_queue_list_v1(text,integer,integer)'::regprocedure,
      'public.gifting_enquiry_queue_set_status_v1(uuid,text)'::regprocedure,
      'public.gifting_enquiry_queue_authorized()'::regprocedure)),
  'queue functions are SECURITY DEFINER with a fixed search_path'
);

-- ---------------------------------------------------------------------------
-- Authorization: only an active admin / super_admin
-- ---------------------------------------------------------------------------
reset request.jwt.claim.sub;
select throws_ok(
  $$ select * from public.gifting_enquiry_queue_list_v1() $$,
  '42501', 'GIFTING_QUEUE_FORBIDDEN', 'an unauthenticated caller cannot list the queue'
);

set local request.jwt.claim.sub = '93000000-0000-0000-0000-000000000004';
select throws_ok(
  $$ select * from public.gifting_enquiry_queue_list_v1() $$,
  '42501', 'GIFTING_QUEUE_FORBIDDEN', 'ordinary staff (support_executive) cannot list the queue'
);
select throws_ok(
  $$ select public.gifting_enquiry_queue_set_status_v1('93200000-0000-0000-0000-000000000001', 'triaged') $$,
  '42501', 'GIFTING_QUEUE_FORBIDDEN', 'ordinary staff cannot change a status'
);

set local request.jwt.claim.sub = '93000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ select * from public.gifting_enquiry_queue_list_v1() $$,
  '42501', 'GIFTING_QUEUE_FORBIDDEN', 'an inactive admin cannot list the queue'
);
select throws_ok(
  $$ select public.gifting_enquiry_queue_set_status_v1('93200000-0000-0000-0000-000000000001', 'triaged') $$,
  '42501', 'GIFTING_QUEUE_FORBIDDEN', 'an inactive admin cannot change a status'
);
select is(
  (select status from public.gifting_enquiries where id = '93200000-0000-0000-0000-000000000001'),
  'received',
  'rejected callers changed nothing'
);

-- ---------------------------------------------------------------------------
-- Active admin
-- ---------------------------------------------------------------------------
set local request.jwt.claim.sub = '93000000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.gifting_enquiry_queue_list_v1()), 3, 'an active admin lists all enquiries');
select is(
  (select id::text from public.gifting_enquiry_queue_list_v1() limit 1),
  '93200000-0000-0000-0000-000000000003',
  'newest enquiry is listed first'
);
select is((select count(*)::int from public.gifting_enquiry_queue_list_v1('received')), 2, 'status filter returns only that status');
select is((select count(*)::int from public.gifting_enquiry_queue_list_v1(null, 1, 0)), 1, 'limit is honoured');
select is(
  (select id::text from public.gifting_enquiry_queue_list_v1(null, 1, 1)),
  '93200000-0000-0000-0000-000000000002',
  'offset pages deterministically'
);
select ok(
  (select array_agg(u.n order by u.ord)
     from pg_proc p, unnest(p.proargnames, p.proargmodes) with ordinality as u(n, m, ord)
    where p.oid = 'public.gifting_enquiry_queue_list_v1(text,integer,integer)'::regprocedure and u.m = 't')
  @> array['id', 'kind', 'email', 'phone', 'message', 'status']::text[]
  and not coalesce(
    (select array_agg(u.n)
       from pg_proc p, unnest(p.proargnames, p.proargmodes) as u(n, m)
      where p.oid = 'public.gifting_enquiry_queue_list_v1(text,integer,integer)'::regprocedure and u.m = 't')
    && array['payload_hash', 'consumer_id', 'source_lead_id', 'attribution']::text[], false),
  'list exposes triage fields and hides the idempotency hash, consumer, source lead id and attribution'
);
select throws_ok($$ select * from public.gifting_enquiry_queue_list_v1('bogus') $$, '22023', 'GIFTING_QUEUE_INVALID', 'unknown status filter is rejected');
select throws_ok($$ select * from public.gifting_enquiry_queue_list_v1(null, 0, 0) $$, '22023', 'GIFTING_QUEUE_INVALID', 'limit below 1 is rejected');
select throws_ok($$ select * from public.gifting_enquiry_queue_list_v1(null, 101, 0) $$, '22023', 'GIFTING_QUEUE_INVALID', 'limit above 100 is rejected');
select throws_ok($$ select * from public.gifting_enquiry_queue_list_v1(null, 10, -1) $$, '22023', 'GIFTING_QUEUE_INVALID', 'negative offset is rejected');

select is(
  (public.gifting_enquiry_queue_set_status_v1('93200000-0000-0000-0000-000000000001', 'triaged') ->> 'status'),
  'triaged',
  'an active admin can triage an enquiry'
);
select is(
  (select status_changed_by::text from public.gifting_enquiries where id = '93200000-0000-0000-0000-000000000001'),
  '93000000-0000-0000-0000-000000000001',
  'the acting staff user is recorded'
);
select ok(
  (select status_changed_at is not null from public.gifting_enquiries where id = '93200000-0000-0000-0000-000000000001'),
  'the change time is recorded'
);
select throws_ok(
  $$ select public.gifting_enquiry_queue_set_status_v1('93200000-0000-0000-0000-000000000001', 'deleted') $$,
  '22023', 'GIFTING_QUEUE_INVALID', 'an unknown status is rejected'
);
select throws_ok(
  $$ select public.gifting_enquiry_queue_set_status_v1('93200000-0000-0000-0000-0000000000ff', 'closed') $$,
  'P0002', 'GIFTING_QUEUE_NOT_FOUND', 'an unknown enquiry is reported, not silently ignored'
);

set local request.jwt.claim.sub = '93000000-0000-0000-0000-000000000002';
select is(
  (public.gifting_enquiry_queue_set_status_v1('93200000-0000-0000-0000-000000000002', 'spam') ->> 'status'),
  'spam',
  'a super_admin can mark spam'
);
select is(
  (select count(*)::int from public.gifting_enquiry_queue_list_v1('spam')), 1,
  'the spam filter reflects the change'
);
select is(
  (select count(*)::int from public.gifting_enquiries), 3,
  'triage never deletes or duplicates an enquiry'
);

select * from finish();

rollback;
