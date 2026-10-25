begin;
-- Proofs for 20261024137000_whatsapp_case_task_supervisor_gate_v1.sql (owner policy for Core PR #451).
-- Uses the REAL production roles: support_executive (holds wa.intake.assign) and admin (supervisory allowlist).
select plan(24);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local session_replication_role = replica;
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a7000000-0000-0000-0000-000000000301', '919830000701', 'Supervisor Gate Test');
insert into public.whatsapp_message_packets(id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status) values
  ('a7000000-0000-0000-0000-000000000311', 'a7000000-0000-0000-0000-000000000301', '{"text":"x"}'::jsonb, 1, (now() at time zone 'UTC'), (now() at time zone 'UTC'), 'open');
insert into public.whatsapp_communication_cases(id, packet_id, case_type, status, source_channel, rule_version, accountable_team, accountability_status) values
  ('a7000000-0000-0000-0000-000000000321', 'a7000000-0000-0000-0000-000000000311', 'ENQUIRY', 'OPEN', 'WHATSAPP', 'packet-ai-b2b-v1', 'CUSTOMER_SERVICE', 'UNASSIGNED');
insert into public.whatsapp_case_department_tasks(id, case_id, department, task_type, instructions, status, due_at, correlation_key, created_by) values
  ('a7000000-0000-0000-0000-000000000401', 'a7000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't1', 'OPEN', now() + interval '1 day', 'g-1', 'a7000000-0000-0000-0000-0000000000f1'),
  ('a7000000-0000-0000-0000-000000000402', 'a7000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't2', 'OPEN', now() + interval '1 day', 'g-2', 'a7000000-0000-0000-0000-0000000000f1'),
  ('a7000000-0000-0000-0000-000000000403', 'a7000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't3', 'OPEN', now() + interval '1 day', 'g-3', 'a7000000-0000-0000-0000-0000000000f1');
set local session_replication_role = origin;

insert into public.users(id, email, role, is_active, department) values
  ('a7000000-0000-0000-0000-000000000011', 'gate-s1@test.invalid', 'SUPPORT_EXECUTIVE', true, null),
  ('a7000000-0000-0000-0000-000000000012', 'gate-s2@test.invalid', 'SUPPORT_EXECUTIVE', true, null),
  ('a7000000-0000-0000-0000-000000000013', 'gate-admin@test.invalid', 'ADMIN', true, null)
on conflict (id) do update set is_active = excluded.is_active, deleted_at = null, department = excluded.department;
insert into public.user_role_map(user_id, role_id)
select u.id, r.id from (values
  ('a7000000-0000-0000-0000-000000000011'::uuid, 'support_executive'),
  ('a7000000-0000-0000-0000-000000000012'::uuid, 'support_executive'),
  ('a7000000-0000-0000-0000-000000000013'::uuid, 'admin')
) u(id, role_key) join public.roles r on r.role_key = u.role_key
on conflict (user_id, role_id) do nothing;

-- Allowlist and helper surface.
select is(public.whatsapp_ownership_supervisor_role_keys(), array['admin','super_admin']::text[], 'the supervisory allowlist is exactly admin and super_admin');
select ok(
  has_function_privilege('authenticated', 'public.whatsapp_is_ownership_supervisor()', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_is_ownership_supervisor()', 'execute')
  and not has_function_privilege('authenticated', 'public.whatsapp_ownership_supervisor_role_keys()', 'execute'),
  'supervisor check is callable by signed-in users only; the allowlist function stays internal'
);
select ok(
  exists(select 1 from public.role_permission_grants where role_key = 'support_executive' and permission_key = 'wa.intake.assign' and effect = 'allow'),
  'precondition: support_executive still holds wa.intake.assign (production grants are untouched)'
);

-- Support executive S1: not a supervisor, but can claim, complete and return their own tasks.
select set_config('request.jwt.claims', json_build_object('sub', 'a7000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(public.whatsapp_is_ownership_supervisor(), false, 'a support executive is not an ownership supervisor despite holding wa.intake.assign');
select is(
  (public.whatsapp_claim_case_task('a7000000-0000-0000-0000-000000000401', 'g-s1-claim-1') ->> 'assigned_user_id'),
  'a7000000-0000-0000-0000-000000000011', 'a support executive can claim an eligible task'
);
select is(
  public.whatsapp_complete_case_task('a7000000-0000-0000-0000-000000000401', '{"outcome":"done"}'::jsonb, 'g-s1-done') ->> 'status',
  'COMPLETED', 'a support executive can complete their claimed task'
);
select public.whatsapp_claim_case_task('a7000000-0000-0000-0000-000000000402', 'g-s1-claim-2');
select is(
  (public.whatsapp_release_case_task('a7000000-0000-0000-0000-000000000402', 'g-s1-rel') ->> 'assigned_user_id'),
  null, 'a support executive can return their own task without a reason'
);
select public.whatsapp_claim_case_task('a7000000-0000-0000-0000-000000000402', 'g-s1-claim-3');
select throws_ok(
  $$select public.whatsapp_assign_case_task('a7000000-0000-0000-0000-000000000403', 'a7000000-0000-0000-0000-000000000012', 'g-s1-assign')$$,
  '42501', 'ownership supervisor role required to assign tasks', 'a support executive cannot assign an unowned task to someone else'
);
select throws_ok(
  $$select public.whatsapp_assign_case_task('a7000000-0000-0000-0000-000000000402', 'a7000000-0000-0000-0000-000000000011', 'g-s1-self', 'my reason')$$,
  '42501', null, 'a support executive cannot use assign on their own task either'
);
reset role;

-- Support executive S2: cannot override S1.
select set_config('request.jwt.claims', json_build_object('sub', 'a7000000-0000-0000-0000-000000000012', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_assign_case_task('a7000000-0000-0000-0000-000000000402', 'a7000000-0000-0000-0000-000000000012', 'g-s2-steal', 'I need it')$$,
  '42501', null, 'a support executive cannot take a colleague''s task by assigning it to themselves, even with a reason'
);
select throws_ok(
  $$select public.whatsapp_release_case_task('a7000000-0000-0000-0000-000000000402', 'g-s2-rel', 'cover')$$,
  '42501', 'only the task owner or an ownership supervisor can release a task', 'a support executive cannot release a colleague''s task, even with a reason'
);
select throws_ok(
  $$select public.whatsapp_claim_case_task('a7000000-0000-0000-0000-000000000402', 'g-s2-claim')$$,
  '55P03', 'CASE_TASK_ALREADY_CLAIMED', 'claim conflicts are still rejected'
);
-- Directory: a non-supervisor sees owners and themselves only, with no departments.
select is(
  (select count(*) from public.whatsapp_case_staff_directory() where user_id in ('a7000000-0000-0000-0000-000000000011', 'a7000000-0000-0000-0000-000000000012', 'a7000000-0000-0000-0000-000000000013')),
  2::bigint, 'a non-supervisor sees the task owner and themselves, not the supervisor who owns nothing'
);
select is(
  (select count(*) from public.whatsapp_case_staff_directory() where department is not null),
  0::bigint, 'a non-supervisor never receives departments'
);
reset role;

-- Supervisor (admin).
select set_config('request.jwt.claims', json_build_object('sub', 'a7000000-0000-0000-0000-000000000013', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(public.whatsapp_is_ownership_supervisor(), true, 'an admin is an ownership supervisor');
select is(
  (public.whatsapp_assign_case_task('a7000000-0000-0000-0000-000000000403', 'a7000000-0000-0000-0000-000000000012', 'g-a-assign') ->> 'assigned_user_id'),
  'a7000000-0000-0000-0000-000000000012', 'a supervisor can assign an unowned task without a reason'
);
select throws_ok(
  $$select public.whatsapp_assign_case_task('a7000000-0000-0000-0000-000000000402', 'a7000000-0000-0000-0000-000000000012', 'g-a-over-1')$$,
  'P0001', 'CASE_TASK_OVERRIDE_REASON_REQUIRED: a reason is required to take a task away from its owner', 'a supervisor override without a reason is rejected'
);
select is(
  (public.whatsapp_assign_case_task('a7000000-0000-0000-0000-000000000402', 'a7000000-0000-0000-0000-000000000012', 'g-a-over-2', 'S1 on leave') ->> 'assigned_user_id'),
  'a7000000-0000-0000-0000-000000000012', 'a supervisor override with a reason succeeds'
);
select throws_ok(
  $$select public.whatsapp_release_case_task('a7000000-0000-0000-0000-000000000402', 'g-a-rel-1')$$,
  'P0001', null, 'a supervisor releasing someone else''s task without a reason is rejected'
);
select is(
  (public.whatsapp_release_case_task('a7000000-0000-0000-0000-000000000402', 'g-a-rel-2', 'rebalancing the queue') ->> 'assigned_user_id'),
  null, 'a supervisor can release someone else''s task with a reason'
);
select is(
  (select count(*) from public.whatsapp_case_staff_directory() where user_id in ('a7000000-0000-0000-0000-000000000011', 'a7000000-0000-0000-0000-000000000012', 'a7000000-0000-0000-0000-000000000013')),
  3::bigint, 'a supervisor sees all eligible operators'
);
reset role;

select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'a7000000-0000-0000-0000-000000000321'
     and event_type in ('DEPARTMENT_TASK_ASSIGNED', 'DEPARTMENT_TASK_RELEASED') and (metadata ->> 'override')::boolean),
  2::bigint, 'only the two supervisor overrides are flagged as overrides'
);
select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'a7000000-0000-0000-0000-000000000321'
     and actor_id = 'a7000000-0000-0000-0000-000000000012'),
  0::bigint, 'the rejected takeover attempts wrote no audit event'
);

-- Anonymous callers.
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
set local role anon;
select throws_ok($$select public.whatsapp_is_ownership_supervisor()$$, '42501', null, 'anon cannot call the supervisor check');
reset role;

select * from finish();
rollback;
