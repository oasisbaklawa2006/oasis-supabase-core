-- Behavioral acceptance for 20260901005000_whatsapp_operator_workspace_persistence.sql.
begin;
select plan(23);

insert into auth.users (id, email) values
  ('87000000-0000-0000-0000-000000000001', 'waop-admin@example.test'),
  ('87000000-0000-0000-0000-000000000002', 'waop-peer@example.test');
insert into public.users (id, email, name, role, is_active) values
  ('87000000-0000-0000-0000-000000000001', 'waop-admin@example.test', 'WAOP Admin', 'admin', true),
  ('87000000-0000-0000-0000-000000000002', 'waop-peer@example.test', 'WAOP Peer', 'admin', true);
insert into public.user_role_map (user_id, role_id)
select u.id, r.id
from (values
  ('87000000-0000-0000-0000-000000000001'::uuid),
  ('87000000-0000-0000-0000-000000000002'::uuid)
) u(id)
cross join public.roles r
where r.role_key = 'admin';

insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('87000000-0000-0000-0000-000000000010', '919444444444', 'WAOP Contact');
insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, first_message_at, last_message_at
) values (
  '87000000-0000-0000-0000-000000000020',
  '87000000-0000-0000-0000-000000000010',
  '{}'::jsonb,
  now(),
  now()
);
insert into public.whatsapp_communication_cases (id, packet_id, rule_version) values
  ('87000000-0000-0000-0000-000000000030', '87000000-0000-0000-0000-000000000020', 'waop-fixture-v1');

-- packet without case for isolation checks
insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, first_message_at, last_message_at
) values (
  '87000000-0000-0000-0000-000000000021',
  '87000000-0000-0000-0000-000000000010',
  '{}'::jsonb,
  now(),
  now()
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '87000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$select public.upsert_whatsapp_operator_note(
      '87000000-0000-0000-0000-000000000020',
      'Customer prefers morning delivery',
      'waop-note-1'
    )$$,
  'authorized operator upserts packet note'
);
select lives_ok(
  $$select public.upsert_whatsapp_operator_note(
      '87000000-0000-0000-0000-000000000020',
      'changed body should not apply on replay',
      'waop-note-1'
    )$$,
  'duplicate note submit is idempotent'
);
select is(
  (select note_body from public.whatsapp_operator_packet_notes where idempotency_key = 'waop-note-1'),
  'Customer prefers morning delivery',
  'replay cannot overwrite released note content'
);
select lives_ok(
  $$select public.upsert_whatsapp_operator_note(
      '87000000-0000-0000-0000-000000000020',
      'Updated delivery preference',
      'waop-note-2'
    )$$,
  'operator may revise their packet note via new idempotency key'
);
select is(
  (select note_body from public.whatsapp_operator_packet_notes
    where packet_id = '87000000-0000-0000-0000-000000000020'
      and actor_id = '87000000-0000-0000-0000-000000000001'),
  'Updated delivery preference',
  'one active note per operator per packet is upserted'
);

select lives_ok(
  $$select public.save_whatsapp_operator_view(
      'urgent-clarifications',
      'Urgent clarifications',
      '{"status":["AWAITING_CLARIFICATION"],"sort":"received_at_desc"}'::jsonb,
      'waop-view-1'
    )$$,
  'operator saves inbox view preset'
);
select lives_ok(
  $$select public.save_whatsapp_operator_view(
      'urgent-clarifications',
      'Changed label on replay',
      '{"status":["AWAITING_CLARIFICATION"]}'::jsonb,
      'waop-view-1'
    )$$,
  'saved view replay is idempotent'
);
select is(
  (select view_label from public.whatsapp_operator_saved_views where idempotency_key = 'waop-view-1'),
  'Urgent clarifications',
  'replay cannot overwrite saved view content'
);

select lives_ok(
  $$select public.record_whatsapp_operator_correction(
      '87000000-0000-0000-0000-000000000030',
      '87000000-0000-0000-0000-000000000020',
      'routing_department',
      '"QUALITY"'::jsonb,
      'waop-corr-1',
      '"SALES"'::jsonb,
      'Operator rerouted after review'
    )$$,
  'authorized operator records case correction'
);
select lives_ok(
  $$select public.record_whatsapp_operator_correction(
      '87000000-0000-0000-0000-000000000030',
      '87000000-0000-0000-0000-000000000020',
      'routing_department',
      '"OPERATIONS"'::jsonb,
      'waop-corr-2',
      null,
      'Second correction supersedes first'
    )$$,
  'later correction supersedes prior active value'
);
select is(
  (select count(*) from public.whatsapp_operator_case_corrections
    where case_id = '87000000-0000-0000-0000-000000000030'
      and correction_field = 'routing_department'),
  2::bigint,
  'both correction rows remain auditable'
);
select is(
  (select count(*) from public.whatsapp_operator_case_corrections
    where case_id = '87000000-0000-0000-0000-000000000030'
      and correction_field = 'routing_department'
      and is_active),
  1::bigint,
  'only one active correction per field'
);
select is(
  (select corrected_value from public.whatsapp_operator_case_corrections
    where idempotency_key = 'waop-corr-2'),
  '"OPERATIONS"'::jsonb,
  'active correction reflects latest superseding value'
);

select throws_ok(
  $$select public.record_whatsapp_operator_correction(
      '87000000-0000-0000-0000-000000000030',
      '87000000-0000-0000-0000-000000000021',
      'routing_department',
      '"QUALITY"'::jsonb,
      'waop-corr-mismatch'
    )$$,
  'WA_OPERATOR_CASE_PACKET_MISMATCH',
  'case/packet mismatch fails closed'
);

select isnt_empty(
  $$select 1
    from (select public.whatsapp_get_case_decision_snapshot('87000000-0000-0000-0000-000000000020') as snap) s
    where (s.snap->'operator_workspace'->'packet_notes') @> '[{"idempotency_key":"waop-note-2"}]'::jsonb$$,
  'snapshot hydrates packet notes'
);
select isnt_empty(
  $$select 1
    from (select public.whatsapp_get_case_decision_snapshot('87000000-0000-0000-0000-000000000020') as snap) s
    where jsonb_array_length(s.snap->'operator_workspace'->'case_corrections') = 2$$,
  'snapshot hydrates correction lineage'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '87000000-0000-0000-0000-000000000002', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;
select lives_ok(
  $$select public.upsert_whatsapp_operator_note(
      '87000000-0000-0000-0000-000000000020',
      'Peer operator note',
      'waop-note-1'
    )$$,
  'another operator may reuse their own idempotency namespace independently'
);
select is(
  (select count(*) from public.whatsapp_operator_packet_notes
    where packet_id = '87000000-0000-0000-0000-000000000020'
      and idempotency_key = 'waop-note-1'),
  2::bigint,
  'shared idempotency keys remain isolated per actor'
);
select is_empty(
  $$select 1
    from (select public.whatsapp_get_case_decision_snapshot('87000000-0000-0000-0000-000000000020') as snap) s
    where s.snap->'operator_workspace'->'saved_views' @> '[{"view_key":"urgent-clarifications"}]'::jsonb$$,
  'snapshot never exposes another user saved views'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '87000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;
select throws_ok(
  $$update public.whatsapp_operator_case_corrections
      set corrected_value = '"TAMPERED"'::jsonb
    where idempotency_key = 'waop-corr-1'$$,
  'WA_OPERATOR_GOVERNED_MUTATION_REQUIRED',
  'direct correction mutation is blocked'
);
select throws_ok(
  $$delete from public.whatsapp_operator_case_corrections
    where idempotency_key = 'waop-corr-1'$$,
  'WA_OPERATOR_APPEND_ONLY',
  'correction delete is blocked'
);

select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.upsert_whatsapp_operator_note(
      '87000000-0000-0000-0000-000000000020',
      'blocked',
      'waop-anon'
    )$$,
  'WA_OPERATOR_TRIAGE_REQUIRED',
  'unauthorized caller cannot write operator notes'
);
select throws_ok(
  $$select public.whatsapp_get_case_decision_snapshot('87000000-0000-0000-0000-000000000020')$$,
  'WhatsApp inbox read permission required',
  'unauthorized caller cannot hydrate snapshot'
);

select * from finish();
rollback;
