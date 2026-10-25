begin;
-- Proofs for 20261024136000_whatsapp_case_task_ownership_hardening_v1.sql (Core PR #451 audit).
-- Rollback: re-apply the function bodies from 20261024135000 (or drop the four ownership functions) and
-- drop index whatsapp_case_department_tasks_assigned_user_idx.
select plan(23);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local session_replication_role = replica;

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a6000000-0000-0000-0000-000000000301', '919830000601', 'Hardening Test');
insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'a6000000-0000-0000-0000-000000000311', 'a6000000-0000-0000-0000-000000000301', '{"text":"x"}'::jsonb, 1,
  (now() at time zone 'UTC'), (now() at time zone 'UTC'), 'open'
);
insert into public.whatsapp_communication_cases(
  id, packet_id, case_type, status, source_channel, rule_version, accountable_team, accountability_status
) values (
  'a6000000-0000-0000-0000-000000000321', 'a6000000-0000-0000-0000-000000000311', 'ENQUIRY', 'OPEN', 'WHATSAPP',
  'packet-ai-b2b-v1', 'CUSTOMER_SERVICE', 'UNASSIGNED'
);
insert into public.whatsapp_case_department_tasks(
  id, case_id, department, task_type, instructions, status, due_at, correlation_key, created_by
) values
  ('a6000000-0000-0000-0000-000000000401', 'a6000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't1', 'OPEN', now() + interval '1 day', 'h-1', 'a6000000-0000-0000-0000-0000000000f1'),
  ('a6000000-0000-0000-0000-000000000402', 'a6000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't2', 'OPEN', now() + interval '1 day', 'h-2', 'a6000000-0000-0000-0000-0000000000f1'),
  ('a6000000-0000-0000-0000-000000000403', 'a6000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't3', 'OPEN', now() + interval '1 day', 'h-3', 'a6000000-0000-0000-0000-0000000000f1');
set local session_replication_role = origin;

insert into public.roles(id, role_key, role_name, is_active) values
  ('a6000000-0000-0000-0000-000000000001', 'hard_test_worker', 'Hardening test worker', true),
  ('a6000000-0000-0000-0000-000000000002', 'hard_test_manager', 'Hardening test manager', true),
  ('a6000000-0000-0000-0000-000000000003', 'hard_test_reader', 'Hardening test reader', true)
on conflict (role_key) do update set is_active = true;
insert into public.role_permission_grants(role_key, permission_key, effect) values
  ('hard_test_worker', 'wa.intake.read', 'allow'), ('hard_test_worker', 'wa.intake.triage', 'allow'),
  ('hard_test_manager', 'wa.intake.read', 'allow'), ('hard_test_manager', 'wa.intake.triage', 'allow'), ('hard_test_manager', 'wa.intake.assign', 'allow'),
  ('hard_test_reader', 'wa.intake.read', 'allow')
on conflict (role_key, permission_key) do update set effect = excluded.effect;
insert into public.users(id, email, role, is_active, department) values
  ('a6000000-0000-0000-0000-000000000011', 'hard-w1@test.invalid', 'HARD_TEST_WORKER', true, 'CUSTOMER_SERVICE'),
  ('a6000000-0000-0000-0000-000000000012', 'hard-w2@test.invalid', 'HARD_TEST_WORKER', true, 'CUSTOMER_SERVICE'),
  ('a6000000-0000-0000-0000-000000000013', 'hard-mgr@test.invalid', 'HARD_TEST_MANAGER', true, 'CUSTOMER_SERVICE'),
  ('a6000000-0000-0000-0000-000000000014', 'hard-reader@test.invalid', 'HARD_TEST_READER', true, 'FINANCE')
on conflict (id) do update set is_active = excluded.is_active, deleted_at = null, department = excluded.department;
insert into public.user_role_map(user_id, role_id)
select u.id, r.id from (values
  ('a6000000-0000-0000-0000-000000000011'::uuid, 'hard_test_worker'),
  ('a6000000-0000-0000-0000-000000000012'::uuid, 'hard_test_worker'),
  ('a6000000-0000-0000-0000-000000000013'::uuid, 'admin'),
  ('a6000000-0000-0000-0000-000000000014'::uuid, 'hard_test_reader')
) u(id, role_key) join public.roles r on r.role_key = u.role_key
on conflict (user_id, role_id) do nothing;

-- W1 claims t1 and t2.
select set_config('request.jwt.claims', json_build_object('sub', 'a6000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select public.whatsapp_claim_case_task('a6000000-0000-0000-0000-000000000401', 'h-claim-1');
select public.whatsapp_claim_case_task('a6000000-0000-0000-0000-000000000402', 'h-claim-2');
reset role;

-- Manager overrides.
select set_config('request.jwt.claims', json_build_object('sub', 'a6000000-0000-0000-0000-000000000013', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_assign_case_task('a6000000-0000-0000-0000-000000000401', 'a6000000-0000-0000-0000-000000000012', 'h-m-1')$$,
  'P0001', 'CASE_TASK_OVERRIDE_REASON_REQUIRED: a reason is required to take a task away from its owner',
  'taking a task from its owner without a reason is rejected'
);
select throws_ok(
  $$select public.whatsapp_assign_case_task('a6000000-0000-0000-0000-000000000401', 'a6000000-0000-0000-0000-000000000013', 'h-m-2', '   ')$$,
  'P0001', null, 'a blank reason does not count, so an assigner cannot self-assign a claimed task silently'
);
select is(
  (public.whatsapp_assign_case_task('a6000000-0000-0000-0000-000000000401', 'a6000000-0000-0000-0000-000000000012', 'h-m-3', 'owner on leave') ->> 'assigned_user_id'),
  'a6000000-0000-0000-0000-000000000012', 'an override with a reason succeeds'
);
select is(
  (public.whatsapp_assign_case_task('a6000000-0000-0000-0000-000000000403', 'a6000000-0000-0000-0000-000000000011', 'h-m-4') ->> 'assigned_user_id'),
  'a6000000-0000-0000-0000-000000000011', 'assigning an unowned task needs no reason'
);
select throws_ok(
  $$select public.whatsapp_release_case_task('a6000000-0000-0000-0000-000000000402', 'h-m-5')$$,
  'P0001', 'CASE_TASK_OVERRIDE_REASON_REQUIRED: a reason is required to release a task owned by someone else',
  'releasing someone else''s task without a reason is rejected'
);
select is(
  (public.whatsapp_release_case_task('a6000000-0000-0000-0000-000000000402', 'h-m-6', 'escalated to the shared queue') ->> 'assigned_user_id'),
  null, 'releasing someone else''s task with a reason succeeds'
);
reset role;

select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'a6000000-0000-0000-0000-000000000321'
    and event_type in ('DEPARTMENT_TASK_ASSIGNED', 'DEPARTMENT_TASK_RELEASED') and (metadata ->> 'override')::boolean),
  2::bigint, 'both overrides are flagged in the audit events'
);
select is(
  (select metadata ->> 'reason' from public.whatsapp_case_events where case_id = 'a6000000-0000-0000-0000-000000000321'
    and correlation_key = 'task-assign:a6000000-0000-0000-0000-000000000401:h-m-3'),
  'owner on leave', 'the override reason is recorded'
);
select is(
  (select (metadata ->> 'override')::boolean from public.whatsapp_case_events where case_id = 'a6000000-0000-0000-0000-000000000321'
    and correlation_key = 'task-assign:a6000000-0000-0000-0000-000000000403:h-m-4'),
  false, 'assigning an unowned task is not an override'
);

-- An owner moves or returns their own task without a reason.
select set_config('request.jwt.claims', json_build_object('sub', 'a6000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  (public.whatsapp_release_case_task('a6000000-0000-0000-0000-000000000403', 'h-w1-rel') ->> 'assigned_user_id'),
  null, 'an owner can return their own task without a reason'
);
reset role;
select is(
  (select (metadata ->> 'override')::boolean from public.whatsapp_case_events where case_id = 'a6000000-0000-0000-0000-000000000321'
    and correlation_key = 'task-release:a6000000-0000-0000-0000-000000000403:h-w1-rel'),
  false, 'an owner release is not an override'
);

-- Directory: a reader-only user sees owners only, no departments.
select set_config('request.jwt.claims', json_build_object('sub', 'a6000000-0000-0000-0000-000000000014', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  (select count(*) from public.whatsapp_case_staff_directory()),
  1::bigint, 'a non-assigner sees only operators who own a task (W2 owns t1)'
);
select is(
  (select user_id::text from public.whatsapp_case_staff_directory()),
  'a6000000-0000-0000-0000-000000000012', 'the visible operator is the task owner'
);
select is(
  (select count(*) from public.whatsapp_case_staff_directory() where department is not null),
  0::bigint, 'a non-assigner never receives departments'
);
select is(
  (select count(*) from public.whatsapp_case_staff_directory() where user_id = 'a6000000-0000-0000-0000-000000000014'),
  0::bigint, 'a reader without triage is not listed'
);
reset role;

-- Directory: an assigner sees every eligible operator with department, and nobody ineligible.
select set_config('request.jwt.claims', json_build_object('sub', 'a6000000-0000-0000-0000-000000000013', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  (select count(*) from public.whatsapp_case_staff_directory() where user_id in
    ('a6000000-0000-0000-0000-000000000011', 'a6000000-0000-0000-0000-000000000012', 'a6000000-0000-0000-0000-000000000013')),
  3::bigint, 'an assigner sees all eligible operators'
);
select is(
  (select department from public.whatsapp_case_staff_directory() where user_id = 'a6000000-0000-0000-0000-000000000011'),
  'CUSTOMER_SERVICE', 'an assigner sees departments'
);
select is(
  (select count(*) from public.whatsapp_case_staff_directory() where user_id = 'a6000000-0000-0000-0000-000000000014'),
  0::bigint, 'an assigner still never sees a reader without triage'
);
reset role;

-- Directory never exposes contact details.
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'whatsapp_case_staff_directory'
      and pg_get_function_result(p.oid) = 'TABLE(user_id uuid, display_name text, department text)'),
  1::bigint, 'directory columns are limited to id, display name and department'
);

select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
set local role anon;
select throws_ok($$select * from public.whatsapp_case_staff_directory()$$, '42501', null, 'anon cannot read the directory');
reset role;

select ok(
  has_function_privilege('authenticated', 'public.whatsapp_assign_case_task(uuid,uuid,text,text)', 'execute')
  and has_function_privilege('authenticated', 'public.whatsapp_release_case_task(uuid,text,text)', 'execute')
  and has_function_privilege('authenticated', 'public.whatsapp_case_staff_directory()', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_assign_case_task(uuid,uuid,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_release_case_task(uuid,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_case_staff_directory()', 'execute'),
  'grants are unchanged after the hardening'
);
select ok(
  not has_function_privilege('authenticated', 'public.whatsapp_case_task_assignee_eligible(uuid)', 'execute'),
  'the eligibility helper stays internal'
);
select has_index('public', 'whatsapp_case_department_tasks', 'whatsapp_case_department_tasks_assigned_user_idx', 'owner lookup index exists');

select * from finish();
rollback;
