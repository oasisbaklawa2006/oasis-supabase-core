begin;
-- Proofs for 20261024138000_whatsapp_case_task_ownership_review_fixes_v1.sql (CodeRabbit findings on Core PR #451).
select plan(11);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local session_replication_role = replica;
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a9000000-0000-0000-0000-000000000301', '919830000901', 'Review Fix Test');
insert into public.whatsapp_message_packets(id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status) values
  ('a9000000-0000-0000-0000-000000000311', 'a9000000-0000-0000-0000-000000000301', '{"text":"x"}'::jsonb, 1, (now() at time zone 'UTC'), (now() at time zone 'UTC'), 'open');
insert into public.whatsapp_communication_cases(id, packet_id, case_type, status, source_channel, rule_version, accountable_team, accountability_status) values
  ('a9000000-0000-0000-0000-000000000321', 'a9000000-0000-0000-0000-000000000311', 'ENQUIRY', 'OPEN', 'WHATSAPP', 'packet-ai-b2b-v1', 'CUSTOMER_SERVICE', 'UNASSIGNED');
insert into public.whatsapp_case_department_tasks(id, case_id, department, task_type, instructions, status, due_at, correlation_key, created_by) values
  ('a9000000-0000-0000-0000-000000000401', 'a9000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'A', 't1', 'OPEN', now() + interval '1 day', 'r-1', 'a9000000-0000-0000-0000-0000000000f1'),
  ('a9000000-0000-0000-0000-000000000402', 'a9000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'A', 't2', 'OPEN', now() + interval '1 day', 'r-2', 'a9000000-0000-0000-0000-0000000000f1'),
  ('a9000000-0000-0000-0000-000000000403', 'a9000000-0000-0000-0000-000000000321', 'CUSTOMER_SERVICE', 'A', 't3', 'OPEN', now() + interval '1 day', 'r-3', 'a9000000-0000-0000-0000-0000000000f1');
set local session_replication_role = origin;

insert into public.users(id, email, role, is_active) values
  ('a9000000-0000-0000-0000-000000000011', 'rf-s1@test.invalid', 'SUPPORT_EXECUTIVE', true),
  ('a9000000-0000-0000-0000-000000000012', 'rf-s2@test.invalid', 'SUPPORT_EXECUTIVE', true),
  ('a9000000-0000-0000-0000-000000000013', 'rf-admin@test.invalid', 'ADMIN', true),
  ('a9000000-0000-0000-0000-000000000014', 'rf-none@test.invalid', 'NONE', true)
on conflict (id) do update set is_active = excluded.is_active, deleted_at = null;
insert into public.user_role_map(user_id, role_id)
select u.id, r.id from (values
  ('a9000000-0000-0000-0000-000000000011'::uuid, 'support_executive'),
  ('a9000000-0000-0000-0000-000000000012'::uuid, 'support_executive'),
  ('a9000000-0000-0000-0000-000000000013'::uuid, 'admin')
) u(id, role_key) join public.roles r on r.role_key = u.role_key
on conflict (user_id, role_id) do nothing;

-- Finding 1: an idempotency key is scoped to its task.
select set_config('request.jwt.claims', json_build_object('sub', 'a9000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  (public.whatsapp_claim_case_task('a9000000-0000-0000-0000-000000000401', 'shared-key') ->> 'idempotent_replay')::boolean,
  false, 'first claim with a key is not a replay');
select is(
  (public.whatsapp_claim_case_task('a9000000-0000-0000-0000-000000000401', 'shared-key') ->> 'idempotent_replay')::boolean,
  true, 'the same key on the same task replays');
select is(
  (public.whatsapp_claim_case_task('a9000000-0000-0000-0000-000000000402', 'shared-key') ->> 'idempotent_replay')::boolean,
  false, 'the same key on a SIBLING task in the same case is a real claim, not a false replay');
select is(
  (select assigned_user_id::text from public.whatsapp_case_department_tasks where id = 'a9000000-0000-0000-0000-000000000402'),
  'a9000000-0000-0000-0000-000000000011', 'the sibling task is actually owned');
reset role;
select is(
  (select count(*) from public.whatsapp_case_events where case_id = 'a9000000-0000-0000-0000-000000000321' and event_type = 'DEPARTMENT_TASK_CLAIMED'),
  2::bigint, 'one audit event per real claim');

-- Same scoping for assign and release.
select set_config('request.jwt.claims', json_build_object('sub', 'a9000000-0000-0000-0000-000000000013', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select public.whatsapp_assign_case_task('a9000000-0000-0000-0000-000000000403', 'a9000000-0000-0000-0000-000000000012', 'k2');
select is(
  (public.whatsapp_assign_case_task('a9000000-0000-0000-0000-000000000401', 'a9000000-0000-0000-0000-000000000012', 'k2', 'cover') ->> 'idempotent_replay')::boolean,
  false, 'assign: a reused key on another task is a real assignment');
select is(
  (public.whatsapp_release_case_task('a9000000-0000-0000-0000-000000000403', 'k3', 'tidy') ->> 'idempotent_replay')::boolean,
  false, 'release: first use of a key');
select is(
  (public.whatsapp_release_case_task('a9000000-0000-0000-0000-000000000401', 'k3', 'tidy') ->> 'idempotent_replay')::boolean,
  false, 'release: a reused key on another task is a real release');
reset role;

-- Finding 2: owners of finished tasks are not shown to non-supervisors.
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
update public.whatsapp_case_department_tasks set assigned_user_id = 'a9000000-0000-0000-0000-000000000012', status = 'COMPLETED',
  response_payload = '{"outcome":"done"}'::jsonb, completed_by = 'a9000000-0000-0000-0000-000000000012', completed_at = now()
  where id = 'a9000000-0000-0000-0000-000000000403';
select set_config('request.jwt.claims', json_build_object('sub', 'a9000000-0000-0000-0000-000000000011', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  (select count(*) from public.whatsapp_case_staff_directory() where user_id = 'a9000000-0000-0000-0000-000000000012'),
  0::bigint, 'a non-supervisor does not see an operator whose only task is completed');
reset role;
select set_config('request.jwt.claims', json_build_object('sub', 'a9000000-0000-0000-0000-000000000013', 'role', 'authenticated', 'aal', 'aal1')::text, true);
set local role authenticated;
select is(
  (select count(*) from public.whatsapp_case_staff_directory() where user_id = 'a9000000-0000-0000-0000-000000000012'),
  1::bigint, 'a supervisor still sees every eligible operator');
reset role;

-- Finding 3: eligibility matches the permission check for the ordinary cases.
select ok(
  public.whatsapp_case_task_assignee_eligible('a9000000-0000-0000-0000-000000000011')
  and public.whatsapp_case_task_assignee_eligible('a9000000-0000-0000-0000-000000000013')
  and not public.whatsapp_case_task_assignee_eligible('a9000000-0000-0000-0000-000000000014'),
  'eligibility: support executive and admin yes, a user without roles no');

select * from finish();
rollback;
