begin;
-- Proofs for 20261024135000_whatsapp_case_task_ownership_v1.sql (Central #639 / PR #640).
-- Rollback of the migration: drop function public.whatsapp_claim_case_task(uuid,text),
-- public.whatsapp_assign_case_task(uuid,uuid,text,text), public.whatsapp_release_case_task(uuid,text,text).
select plan(28);

-- Privileges.
select ok(
  has_function_privilege('authenticated', 'public.whatsapp_claim_case_task(uuid,text)', 'execute')
  and has_function_privilege('authenticated', 'public.whatsapp_assign_case_task(uuid,uuid,text,text)', 'execute')
  and has_function_privilege('authenticated', 'public.whatsapp_release_case_task(uuid,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_claim_case_task(uuid,text)', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_assign_case_task(uuid,uuid,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_release_case_task(uuid,text,text)', 'execute'),
  'ownership functions are authenticated-only'
);

-- Fixtures (as the table owner, bypassing FK-heavy upstream rows like the other case tests).
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local session_replication_role = replica;

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a5000000-0000-0000-0000-000000000301', '919830000501', 'Ownership Test');
insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'a5000000-0000-0000-0000-000000000311', 'a5000000-0000-0000-0000-000000000301', '{"text":"enquiry"}'::jsonb, 1,
  (now() at time zone 'UTC'), (now() at time zone 'UTC'), 'open'
);
insert into public.whatsapp_communication_cases(
  id, packet_id, case_type, status, source_channel, rule_version, accountable_team, accountability_status
) values (
  'a5000000-0000-0000-0000-000000000321', 'a5000000-0000-0000-0000-000000000311', 'ENQUIRY', 'OPEN', 'WHATSAPP',
  'packet-ai-b2b-v1', 'CUSTOMER_SERVICE', 'UNASSIGNED'
);
insert into public.whatsapp_case_department_tasks(
  id, case_id, department, task_type, instructions, status, due_at, correlation_key, created_by
) values
  ('a5000000-0000-0000-0000-000000000401', 'a5000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 'claim me', 'OPEN', now() + interval '1 day', 'own-1', 'a5000000-0000-0000-0000-0000000000f1'),
  ('a5000000-0000-0000-0000-000000000402', 'a5000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 'historical untouched', 'OPEN', now() + interval '1 day', 'own-2', 'a5000000-0000-0000-0000-0000000000f1'),
  ('a5000000-0000-0000-0000-000000000403', 'a5000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 'complete me', 'OPEN', now() + interval '1 day', 'own-3', 'a5000000-0000-0000-0000-0000000000f1');
set local session_replication_role = origin;

insert into public.roles(id, role_key, role_name, is_active) values
  ('a5000000-0000-0000-0000-000000000001', 'own_test_worker', 'Ownership test worker', true),
  ('a5000000-0000-0000-0000-000000000002', 'own_test_manager', 'Ownership test manager', true),
  ('a5000000-0000-0000-0000-000000000003', 'own_test_reader', 'Ownership test reader', true)
on conflict (role_key) do update set is_active = true;
insert into public.role_permission_grants(role_key, permission_key, effect) values
  ('own_test_worker', 'wa.intake.read', 'allow'), ('own_test_worker', 'wa.intake.triage', 'allow'),
  ('own_test_manager', 'wa.intake.read', 'allow'), ('own_test_manager', 'wa.intake.triage', 'allow'), ('own_test_manager', 'wa.intake.assign', 'allow'),
  ('own_test_reader', 'wa.intake.read', 'allow')
on conflict (role_key, permission_key) do update set effect = excluded.effect;
insert into public.users(id, email, role, is_active) values
  ('a5000000-0000-0000-0000-000000000011', 'own-a@test.invalid', 'OWN_TEST_WORKER', true),
  ('a5000000-0000-0000-0000-000000000012', 'own-b@test.invalid', 'OWN_TEST_WORKER', true),
  ('a5000000-0000-0000-0000-000000000013', 'own-mgr@test.invalid', 'OWN_TEST_MANAGER', true),
  ('a5000000-0000-0000-0000-000000000014', 'own-reader@test.invalid', 'OWN_TEST_READER', true),
  ('a5000000-0000-0000-0000-000000000015', 'own-inactive@test.invalid', 'OWN_TEST_WORKER', false)
on conflict (id) do update set is_active = excluded.is_active, deleted_at = null;
insert into public.user_role_map(user_id, role_id)
select u.id, r.id from (values
  ('a5000000-0000-0000-0000-000000000011'::uuid, 'own_test_worker'),
  ('a5000000-0000-0000-0000-000000000012'::uuid, 'own_test_worker'),
  ('a5000000-0000-0000-0000-000000000013'::uuid, 'own_test_manager'),
  ('a5000000-0000-0000-0000-000000000014'::uuid, 'own_test_reader'),
  ('a5000000-0000-0000-0000-000000000015'::uuid, 'own_test_worker')
) u(id, role_key) join public.roles r on r.role_key = u.role_key
on conflict (user_id, role_id) do nothing;

-- Reader without triage cannot claim.
select set_config('request.jwt.claims', json_build_object('sub', 'a5000000-0000-0000-0000-000000000014', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_claim_case_task('a5000000-0000-0000-0000-000000000401', 'k-reader')$$,
  '42501', null, 'a reader without wa.intake.triage cannot claim'
);
reset role;

-- Worker A claims.
select set_config('request.jwt.claims', json_build_object('sub', 'a5000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  (public.whatsapp_claim_case_task('a5000000-0000-0000-0000-000000000401', 'k-a-1') ->> 'idempotent_replay')::boolean,
  false, 'first claim is not a replay'
);
select is(
  (select assigned_user_id::text || '/' || status from public.whatsapp_case_department_tasks where id = 'a5000000-0000-0000-0000-000000000401'),
  'a5000000-0000-0000-0000-000000000011/IN_PROGRESS', 'claim assigns the caller and starts the task'
);
select is(
  (public.whatsapp_claim_case_task('a5000000-0000-0000-0000-000000000401', 'k-a-1') ->> 'idempotent_replay')::boolean,
  true, 'same idempotency key replays'
);
select public.whatsapp_claim_case_task('a5000000-0000-0000-0000-000000000401', 'k-a-2');
reset role;
select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'a5000000-0000-0000-0000-000000000321' and event_type = 'DEPARTMENT_TASK_CLAIMED'),
  1::bigint, 'replay and re-claim by the owner write exactly one audit event'
);

-- Worker B cannot take an owned task.
select set_config('request.jwt.claims', json_build_object('sub', 'a5000000-0000-0000-0000-000000000012', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_claim_case_task('a5000000-0000-0000-0000-000000000401', 'k-b-1')$$,
  '55P03', 'CASE_TASK_ALREADY_CLAIMED', 'a conflicting claim is rejected'
);
select throws_ok(
  $$select public.whatsapp_assign_case_task('a5000000-0000-0000-0000-000000000401', 'a5000000-0000-0000-0000-000000000012', 'k-b-assign')$$,
  '42501', null, 'a worker without wa.intake.assign cannot assign'
);
reset role;

-- Manager reassigns A -> B.
select set_config('request.jwt.claims', json_build_object('sub', 'a5000000-0000-0000-0000-000000000013', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  (public.whatsapp_assign_case_task('a5000000-0000-0000-0000-000000000401', 'a5000000-0000-0000-0000-000000000012', 'k-m-1', 'cover shift') ->> 'assigned_user_id'),
  'a5000000-0000-0000-0000-000000000012', 'manager reassigns the task'
);
select is(
  (public.whatsapp_assign_case_task('a5000000-0000-0000-0000-000000000401', 'a5000000-0000-0000-0000-000000000012', 'k-m-1', 'cover shift') ->> 'idempotent_replay')::boolean,
  true, 'assign replays idempotently'
);
select throws_ok(
  $$select public.whatsapp_assign_case_task('a5000000-0000-0000-0000-000000000401', 'a5000000-0000-0000-0000-000000000014', 'k-m-2')$$,
  'P0001', null, 'cannot assign to a user without triage permission'
);
select throws_ok(
  $$select public.whatsapp_assign_case_task('a5000000-0000-0000-0000-000000000401', 'a5000000-0000-0000-0000-000000000015', 'k-m-3')$$,
  'P0001', null, 'cannot assign to an inactive user'
);
select throws_ok(
  $$select public.whatsapp_assign_case_task('a5000000-0000-0000-0000-000000000401', 'a5000000-0000-0000-0000-000000000099', 'k-m-4')$$,
  'P0001', null, 'cannot assign to an unknown user'
);
reset role;
select is(
  (select metadata ->> 'previous_assigned_user_id' from public.whatsapp_case_events where case_id = 'a5000000-0000-0000-0000-000000000321' and event_type = 'DEPARTMENT_TASK_ASSIGNED'),
  'a5000000-0000-0000-0000-000000000011', 'the audit event records the previous owner'
);

-- Non-owner cannot release; owner can.
select set_config('request.jwt.claims', json_build_object('sub', 'a5000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_release_case_task('a5000000-0000-0000-0000-000000000401', 'k-a-rel')$$,
  '42501', null, 'a non-owner without wa.intake.assign cannot release'
);
reset role;
select set_config('request.jwt.claims', json_build_object('sub', 'a5000000-0000-0000-0000-000000000012', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  (public.whatsapp_release_case_task('a5000000-0000-0000-0000-000000000401', 'k-b-rel', 'busy') ->> 'assigned_user_id'),
  null, 'owner releases the task to the shared queue'
);
reset role;
select is(
  (select status from public.whatsapp_case_department_tasks where id = 'a5000000-0000-0000-0000-000000000401'),
  'OPEN', 'a released in-progress task returns to OPEN'
);

-- Claim -> complete still works through the existing governed completion RPC.
select set_config('request.jwt.claims', json_build_object('sub', 'a5000000-0000-0000-0000-000000000012', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select public.whatsapp_claim_case_task('a5000000-0000-0000-0000-000000000403', 'k-b-3');
select is(
  public.whatsapp_complete_case_task('a5000000-0000-0000-0000-000000000403', '{"outcome":"done"}'::jsonb, 'k-b-3-done') ->> 'status',
  'COMPLETED', 'a claimed task completes through the existing governed RPC'
);
select throws_ok(
  $$select public.whatsapp_claim_case_task('a5000000-0000-0000-0000-000000000403', 'k-b-3-again')$$,
  'P0001', null, 'a completed task cannot be claimed'
);
select throws_ok(
  $$select public.whatsapp_claim_case_task('a5000000-0000-0000-0000-000000000401', '')$$,
  'P0001', 'idempotency key required', 'an idempotency key is mandatory'
);
reset role;

-- Nothing is auto-assigned.
select is(
  (select assigned_user_id::text from public.whatsapp_case_department_tasks where id = 'a5000000-0000-0000-0000-000000000402'),
  null, 'an untouched historical task stays unassigned'
);
select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'a5000000-0000-0000-0000-000000000321' and event_type in ('DEPARTMENT_TASK_CLAIMED', 'DEPARTMENT_TASK_ASSIGNED', 'DEPARTMENT_TASK_RELEASED')),
  4::bigint, 'claim, claim(task 3), assign and release are the only ownership events'
);
select ok(
  not has_function_privilege('anon', 'public.whatsapp_complete_case_task(uuid,jsonb,text)', 'execute'),
  'existing completion RPC authority unchanged'
);
select ok(
  (select count(*) from pg_trigger where tgrelid = 'public.whatsapp_case_events'::regclass and not tgisinternal) >= 1,
  'case events remain protected by their append-only trigger'
);

select ok(
  not has_function_privilege('authenticated', 'public.whatsapp_case_task_assignee_eligible(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_case_task_assignee_eligible(uuid)', 'execute'),
  'assignee eligibility helper is not callable through the API'
);

-- Staff directory exists, is API-granted to authenticated only, and rejects anon.
-- (Behavioural directory proofs live in 20261024136000_whatsapp_case_task_ownership_hardening_v1.sql.)
select has_function('public', 'whatsapp_case_staff_directory', array[]::text[], 'staff directory exists');
select ok(
  has_function_privilege('authenticated', 'public.whatsapp_case_staff_directory()', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_case_staff_directory()', 'execute'),
  'staff directory is authenticated-only'
);
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
set local role anon;
select throws_ok($$select * from public.whatsapp_case_staff_directory()$$, '42501', null, 'anon cannot read the directory');
reset role;

select * from finish();
rollback;
