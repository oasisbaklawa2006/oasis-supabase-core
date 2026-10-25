begin;
-- Proofs for 20261025140000_whatsapp_case_task_completion_owner_gate_v1.sql (Core #452).
-- Uses the REAL production roles support_executive and admin, plus test-only roles for disabled/deny cases.
select plan(42);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local session_replication_role = replica;
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('ac000000-0000-0000-0000-000000000301', '919830000801', 'Completion Gate Test');
insert into public.whatsapp_message_packets(id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status) values
  ('ac000000-0000-0000-0000-000000000311', 'ac000000-0000-0000-0000-000000000301', '{"text":"x"}'::jsonb, 1, (now() at time zone 'UTC'), (now() at time zone 'UTC'), 'open');
insert into public.whatsapp_communication_cases(id, packet_id, case_type, status, source_channel, rule_version, accountable_team, accountability_status) values
  ('ac000000-0000-0000-0000-000000000321', 'ac000000-0000-0000-0000-000000000311', 'ENQUIRY', 'OPEN', 'WHATSAPP', 'packet-ai-b2b-v1', 'CUSTOMER_SERVICE', 'UNASSIGNED');

-- Users first (tasks reference no user FK, but created_by/assigned_user_id values must be real ids for clarity).
insert into public.roles(id, role_key, role_name, is_active) values
  ('ac000000-0000-0000-0000-000000000001', 'cmp_test_worker', 'Completion test worker', true),
  ('ac000000-0000-0000-0000-000000000002', 'cmp_test_deny', 'Completion test deny', true)
on conflict (role_key) do update set is_active = true;
insert into public.role_permission_grants(role_key, permission_key, effect) values
  ('cmp_test_worker', 'wa.intake.read', 'allow'), ('cmp_test_worker', 'wa.intake.triage', 'allow'),
  ('cmp_test_deny', 'wa.intake.triage', 'deny')
on conflict (role_key, permission_key) do update set effect = excluded.effect;
insert into public.users(id, email, role, is_active, department) values
  ('ac000000-0000-0000-0000-000000000011', 'cmp-s1@test.invalid', 'SUPPORT_EXECUTIVE', true, null),
  ('ac000000-0000-0000-0000-000000000012', 'cmp-s2@test.invalid', 'SUPPORT_EXECUTIVE', true, null),
  ('ac000000-0000-0000-0000-000000000013', 'cmp-admin@test.invalid', 'ADMIN', true, null),
  ('ac000000-0000-0000-0000-000000000014', 'cmp-disabled-role@test.invalid', 'CMP_TEST_WORKER', true, null),
  ('ac000000-0000-0000-0000-000000000015', 'cmp-inactive@test.invalid', 'SUPPORT_EXECUTIVE', false, null),
  ('ac000000-0000-0000-0000-000000000016', 'cmp-deny@test.invalid', 'SUPPORT_EXECUTIVE', true, null)
on conflict (id) do update set is_active = excluded.is_active, deleted_at = null, department = excluded.department;
insert into public.user_role_map(user_id, role_id)
select u.id, r.id from (values
  ('ac000000-0000-0000-0000-000000000011'::uuid, 'support_executive'),
  ('ac000000-0000-0000-0000-000000000012'::uuid, 'support_executive'),
  ('ac000000-0000-0000-0000-000000000013'::uuid, 'admin'),
  ('ac000000-0000-0000-0000-000000000014'::uuid, 'cmp_test_worker'),
  ('ac000000-0000-0000-0000-000000000015'::uuid, 'support_executive'),
  ('ac000000-0000-0000-0000-000000000016'::uuid, 'support_executive'),
  ('ac000000-0000-0000-0000-000000000016'::uuid, 'cmp_test_deny')
) u(id, role_key) join public.roles r on r.role_key = u.role_key
on conflict (user_id, role_id) do nothing;

-- Tasks. T1,T7,T8,T10,T12,T13,T15,T16 start OPEN/unowned; ownership is created through the real claim RPC or by fixture.
insert into public.whatsapp_case_department_tasks(id, case_id, department, task_type, instructions, status, due_at, correlation_key, created_by, assigned_user_id) values
  ('ac000000-0000-0000-0000-000000000401', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't1', 'OPEN', now() + interval '1 day', 'c-1', 'ac000000-0000-0000-0000-000000000011', null),
  ('ac000000-0000-0000-0000-000000000402', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't2', 'IN_PROGRESS', now() + interval '1 day', 'c-2', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000011'),
  ('ac000000-0000-0000-0000-000000000403', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't3 unassigned', 'OPEN', now() + interval '1 day', 'c-3', 'ac000000-0000-0000-0000-000000000011', null),
  ('ac000000-0000-0000-0000-000000000404', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't4 disabled role owner', 'IN_PROGRESS', now() + interval '1 day', 'c-4', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000014'),
  ('ac000000-0000-0000-0000-000000000405', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't5 inactive owner', 'IN_PROGRESS', now() + interval '1 day', 'c-5', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000015'),
  ('ac000000-0000-0000-0000-000000000406', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't6 denied owner', 'IN_PROGRESS', now() + interval '1 day', 'c-6', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000016'),
  ('ac000000-0000-0000-0000-000000000407', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't7 same key a', 'IN_PROGRESS', now() + interval '1 day', 'c-7', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000011'),
  ('ac000000-0000-0000-0000-000000000408', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't8 same key b', 'IN_PROGRESS', now() + interval '1 day', 'c-8', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000011'),
  ('ac000000-0000-0000-0000-000000000410', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't10 legacy key sibling', 'IN_PROGRESS', now() + interval '1 day', 'c-10', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000011'),
  ('ac000000-0000-0000-0000-000000000411', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't11 cancelled', 'CANCELLED', now() + interval '1 day', 'c-11', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000011'),
  ('ac000000-0000-0000-0000-000000000412', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't12 aal2', 'OPEN', now() + interval '1 day', 'c-12', 'ac000000-0000-0000-0000-000000000011', null),
  ('ac000000-0000-0000-0000-000000000413', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't13 released', 'OPEN', now() + interval '1 day', 'c-13', 'ac000000-0000-0000-0000-000000000011', null),
  ('ac000000-0000-0000-0000-000000000415', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't15 unassigned for admin', 'OPEN', now() + interval '1 day', 'c-15', 'ac000000-0000-0000-0000-000000000011', null),
  ('ac000000-0000-0000-0000-000000000416', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't16 owned by s1 for admin', 'IN_PROGRESS', now() + interval '1 day', 'c-16', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000011');
-- T9: already completed by S1 under the LEGACY event key (task-complete:<key>) that older code wrote.
insert into public.whatsapp_case_department_tasks(id, case_id, department, task_type, instructions, status, due_at, correlation_key, created_by, assigned_user_id, response_payload, completed_by, completed_at) values
  ('ac000000-0000-0000-0000-000000000409', 'ac000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'ACCOUNTABLE_RESPONSE_OWNER', 't9 legacy completed', 'COMPLETED', now() + interval '1 day', 'c-9', 'ac000000-0000-0000-0000-000000000011', 'ac000000-0000-0000-0000-000000000011', '{"outcome":"legacy"}'::jsonb, 'ac000000-0000-0000-0000-000000000011', now());
insert into public.whatsapp_case_events(case_id, event_type, actor_id, actor_type, correlation_key, resulting_state, metadata) values
  ('ac000000-0000-0000-0000-000000000321', 'DEPARTMENT_TASK_COMPLETED', 'ac000000-0000-0000-0000-000000000011', 'OPERATOR', 'task-complete:legacy-k',
   '{"task_id":"ac000000-0000-0000-0000-000000000409","status":"COMPLETED"}'::jsonb, '{"outcome":"legacy"}'::jsonb);
set local session_replication_role = origin;
-- The disabled-role owner's role is switched off AFTER the task was assigned to them.
update public.roles set is_active = false where role_key = 'cmp_test_worker';

-- Surface and policy invariants.
select is(
  pg_get_function_identity_arguments('public.whatsapp_complete_case_task(uuid,jsonb,text)'::regprocedure),
  'p_task_id uuid, p_response_payload jsonb, p_idempotency_key text',
  'the completion request signature is unchanged'
);
select ok(
  has_function_privilege('authenticated', 'public.whatsapp_complete_case_task(uuid,jsonb,text)', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_complete_case_task(uuid,jsonb,text)', 'execute'),
  'completion stays callable by signed-in users only'
);
select ok(
  (select not requires_step_up from public.access_permissions where permission_key = 'wa.intake.triage')
  and (select requires_step_up from public.access_permissions where permission_key = 'wa.intake.close')
  and exists (select 1 from public.role_permission_grants where role_key = 'support_executive' and permission_key = 'wa.intake.assign' and effect = 'allow')
  and public.whatsapp_ownership_supervisor_role_keys() = array['admin','super_admin']::text[],
  'step-up flags, wa.intake.assign grants and the supervisor allowlist are untouched'
);

-- S1: claims T1 through the real RPC, then completes it as owner.
select set_config('request.jwt.claims', json_build_object('sub', 'ac000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  public.whatsapp_claim_case_task('ac000000-0000-0000-0000-000000000401', 'c-claim-1') ->> 'assigned_user_id',
  'ac000000-0000-0000-0000-000000000011', 'a support executive claims a task (ownership claim unchanged)'
);
select is(
  public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000401', '{"outcome":"done-1"}'::jsonb, 'c-t1') ->> 'status',
  'COMPLETED', 'the owner completes their claimed task'
);
select is(
  (select completed_by from public.whatsapp_case_department_tasks where id = 'ac000000-0000-0000-0000-000000000401'),
  'ac000000-0000-0000-0000-000000000011'::uuid, 'the owner is recorded as the completer'
);
select is(
  public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000401', '{"outcome":"done-1"}'::jsonb, 'c-t1') ->> 'idempotent_replay',
  'true', 'an exact replay (same task, caller and key) is idempotent'
);
reset role;
select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'ac000000-0000-0000-0000-000000000321' and event_type = 'DEPARTMENT_TASK_COMPLETED' and correlation_key = 'task-complete:ac000000-0000-0000-0000-000000000401:c-t1'),
  1::bigint, 'the replay wrote no second event and the key is task-scoped'
);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000401', '{"outcome":"again"}'::jsonb, 'c-t1-fresh')$$,
  'P0001', 'CASE_TASK_ALREADY_COMPLETED: case task is already completed',
  'completing a finished task with a fresh key is refused'
);
reset role;
select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'ac000000-0000-0000-0000-000000000321' and event_type = 'DEPARTMENT_TASK_COMPLETED' and resulting_state ->> 'task_id' = 'ac000000-0000-0000-0000-000000000401'),
  1::bigint, 'the refused repeat wrote no misleading duplicate completion event'
);
select is(
  (select response_payload ->> 'outcome' from public.whatsapp_case_department_tasks where id = 'ac000000-0000-0000-0000-000000000401'),
  'done-1', 'the original completion response is not overwritten'
);

-- S2 (a different support executive): cannot complete a colleague's or an unassigned task.
select set_config('request.jwt.claims', json_build_object('sub', 'ac000000-0000-0000-0000-000000000012', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000402', '{"outcome":"stolen"}'::jsonb, 'c-s2-steal')$$,
  '42501', 'CASE_TASK_NOT_OWNER: only the task owner can complete it',
  'a non-owner triage operator cannot complete a colleague''s task'
);
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000403', '{"outcome":"x"}'::jsonb, 'c-s2-unassigned')$$,
  '42501', 'CASE_TASK_NOT_CLAIMED: claim the task before completing it',
  'an unassigned task cannot be completed without claiming it first'
);
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000401', '{"outcome":"probe"}'::jsonb, 'c-t1')$$,
  'P0001', 'CASE_TASK_ALREADY_COMPLETED: case task is already completed',
  'another caller reusing a completed task''s key gets no replay'
);
reset role;
select is(
  (select count(*) from public.whatsapp_case_department_tasks where id in ('ac000000-0000-0000-0000-000000000402', 'ac000000-0000-0000-0000-000000000403') and status in ('IN_PROGRESS', 'OPEN') and completed_by is null),
  2::bigint, 'the denied attempts left both task rows untouched'
);
select is(
  (select count(*) from public.whatsapp_case_events where event_type = 'DEPARTMENT_TASK_COMPLETED' and resulting_state ->> 'task_id' in ('ac000000-0000-0000-0000-000000000402', 'ac000000-0000-0000-0000-000000000403')),
  0::bigint, 'the denied attempts wrote no events'
);

-- S1: same key on two tasks of one case.
select set_config('request.jwt.claims', json_build_object('sub', 'ac000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000407', '{"outcome":"a"}'::jsonb, 'same-key') ->> 'status',
  'COMPLETED', 'first task completes with the shared key'
);
select is(
  public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000408', '{"outcome":"b"}'::jsonb, 'same-key') ->> 'idempotent_replay',
  'false', 'the same key on a sibling task is not a replay'
);
reset role;
select is(
  (select status from public.whatsapp_case_department_tasks where id = 'ac000000-0000-0000-0000-000000000408'),
  'COMPLETED', 'the sibling task was really completed, not falsely reported'
);
select is(
  (select count(*) from public.whatsapp_case_events where event_type = 'DEPARTMENT_TASK_COMPLETED' and correlation_key in ('task-complete:ac000000-0000-0000-0000-000000000407:same-key', 'task-complete:ac000000-0000-0000-0000-000000000408:same-key')),
  2::bigint, 'each task has its own task-scoped completion event'
);

-- Legacy-format events.
set local role authenticated;
select is(
  public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000410', '{"outcome":"c"}'::jsonb, 'legacy-k') ->> 'idempotent_replay',
  'false', 'a legacy event for another task is never reinterpreted as this task''s completion'
);
select is(
  public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000409', '{"outcome":"legacy"}'::jsonb, 'legacy-k') ->> 'idempotent_replay',
  'true', 'a legacy completion event for this task and caller still replays'
);
reset role;
select is(
  (select count(*) from public.whatsapp_case_events where event_type = 'DEPARTMENT_TASK_COMPLETED' and correlation_key = 'task-complete:legacy-k'),
  1::bigint, 'the legacy event is untouched and no legacy-format event was added'
);

-- Cancelled task.
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000411', '{"outcome":"x"}'::jsonb, 'c-cancel')$$,
  'P0001', 'cancelled case task cannot be completed', 'a cancelled task cannot be completed'
);
-- Claim, release, then complete without re-claiming.
select public.whatsapp_claim_case_task('ac000000-0000-0000-0000-000000000413', 'c-claim-13');
select public.whatsapp_release_case_task('ac000000-0000-0000-0000-000000000413', 'c-rel-13');
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000413', '{"outcome":"x"}'::jsonb, 'c-t13')$$,
  '42501', 'CASE_TASK_NOT_CLAIMED: claim the task before completing it', 'a released task cannot be completed by its former owner'
);
reset role;
select is(
  (select count(*) from public.whatsapp_case_events where event_type = 'DEPARTMENT_TASK_COMPLETED' and resulting_state ->> 'task_id' in ('ac000000-0000-0000-0000-000000000411', 'ac000000-0000-0000-0000-000000000413')),
  0::bigint, 'cancelled and released tasks produced no completion events'
);

-- Disabled, inactive and denied owners cannot complete tasks assigned to them.
select set_config('request.jwt.claims', json_build_object('sub', 'ac000000-0000-0000-0000-000000000014', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000404', '{"outcome":"x"}'::jsonb, 'c-dis')$$,
  '42501', 'WhatsApp triage permission required', 'an owner whose role was disabled is denied'
);
reset role;
select set_config('request.jwt.claims', json_build_object('sub', 'ac000000-0000-0000-0000-000000000015', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000405', '{"outcome":"x"}'::jsonb, 'c-inact')$$,
  '42501', 'WhatsApp triage permission required', 'an owner whose account is inactive is denied'
);
reset role;
select set_config('request.jwt.claims', json_build_object('sub', 'ac000000-0000-0000-0000-000000000016', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000406', '{"outcome":"x"}'::jsonb, 'c-deny')$$,
  '42501', 'WhatsApp triage permission required', 'an owner with a deny rule on triage is denied'
);
reset role;
select is(
  (select count(*) from public.whatsapp_case_department_tasks where id in ('ac000000-0000-0000-0000-000000000404', 'ac000000-0000-0000-0000-000000000405', 'ac000000-0000-0000-0000-000000000406') and status = 'IN_PROGRESS' and completed_by is null),
  3::bigint, 'the disabled, inactive and denied attempts changed nothing'
);

-- Supervisor (admin): no implicit bypass; the audited assign-then-complete path works.
select set_config('request.jwt.claims', json_build_object('sub', 'ac000000-0000-0000-0000-000000000013', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000415', '{"outcome":"x"}'::jsonb, 'c-adm-1')$$,
  '42501', 'CASE_TASK_NOT_CLAIMED: claim the task before completing it', 'a supervisor cannot complete an unassigned task without claiming it'
);
select throws_ok(
  $$select public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000416', '{"outcome":"x"}'::jsonb, 'c-adm-2')$$,
  '42501', 'CASE_TASK_NOT_OWNER: only the task owner can complete it', 'a supervisor cannot complete a colleague''s task directly'
);
select is(
  public.whatsapp_assign_case_task('ac000000-0000-0000-0000-000000000416', 'ac000000-0000-0000-0000-000000000013', 'c-adm-assign', 'S1 is on leave; finishing the customer reply') ->> 'assigned_user_id',
  'ac000000-0000-0000-0000-000000000013', 'a supervisor takes the task over through the audited, reasoned assign path'
);
select is(
  public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000416', '{"outcome":"finished by supervisor"}'::jsonb, 'c-adm-3') ->> 'status',
  'COMPLETED', 'the supervisor then completes as the owner'
);
reset role;
select is(
  (select metadata ->> 'override' from public.whatsapp_case_events where event_type = 'DEPARTMENT_TASK_ASSIGNED' and correlation_key = 'task-assign:ac000000-0000-0000-0000-000000000416:c-adm-assign'),
  'true', 'the take-over is flagged as an override in the audit trail'
);

-- AAL2 session: the owner path is the same, with no extra requirement and no bypass.
select set_config('request.jwt.claims', json_build_object('sub', 'ac000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;
select public.whatsapp_claim_case_task('ac000000-0000-0000-0000-000000000412', 'c-claim-12');
select is(
  public.whatsapp_complete_case_task('ac000000-0000-0000-0000-000000000412', '{"outcome":"aal2"}'::jsonb, 'c-t12') ->> 'status',
  'COMPLETED', 'an AAL2 owner session completes normally'
);
reset role;

-- Totals and audit integrity.
select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'ac000000-0000-0000-0000-000000000321' and event_type = 'DEPARTMENT_TASK_COMPLETED'),
  7::bigint, 'exactly seven completion events: six real completions plus the legacy fixture event'
);
select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'ac000000-0000-0000-0000-000000000321' and event_type = 'DEPARTMENT_TASK_COMPLETED' and resulting_state ->> 'task_id' is null),
  0::bigint, 'every completion event names its task'
);
select throws_ok(
  $$update public.whatsapp_case_events set metadata = '{}'::jsonb where event_type = 'DEPARTMENT_TASK_COMPLETED'$$,
  null, null, 'completion events remain append-only'
);
select is(
  (select count(*) from public.whatsapp_case_department_tasks where case_id = 'ac000000-0000-0000-0000-000000000321' and status = 'COMPLETED'),
  7::bigint, 'seven tasks end COMPLETED (T1, T7, T8, T9 legacy, T10, T12, T16)'
);
select is(
  (select count(*) from public.whatsapp_case_department_tasks where case_id = 'ac000000-0000-0000-0000-000000000321' and status = 'COMPLETED' and completed_by is null),
  0::bigint, 'no completed task is missing its completer'
);
select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'ac000000-0000-0000-0000-000000000321' and event_type in ('DEPARTMENT_TASK_CLAIMED', 'DEPARTMENT_TASK_ASSIGNED', 'DEPARTMENT_TASK_RELEASED')),
  5::bigint, 'ownership events: claims of T1, T13 and T12, release of T13, assignment of T16'
);

select * from finish();
rollback;
