begin;
-- Review hardening proofs for 20260824110000_whatsapp_autonomy_core_c_review_hardening.sql
select plan(6);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- TEST 1: ambiguous affirmation fails soft without aborting stitch
insert into auth.users (id, email) values ('d1000000-0000-0000-0000-000000000001', 'hard-human@example.test');
insert into public.users (id, email, full_name, role) values
  ('d1000000-0000-0000-0000-000000000001', 'hard-human@example.test', 'Hard Human', 'admin');
select public.whatsapp_core_c_ensure_system_principal();

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('d1000000-0000-0000-0000-000000000301', '919820000011', 'Affirm Customer');
insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'd1000000-0000-0000-0000-000000000311', 'd1000000-0000-0000-0000-000000000301',
  '{"text":"send baklawa"}'::jsonb, 1, statement_timestamp(), statement_timestamp(), 'open'
);
insert into public.whatsapp_communication_cases(
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  'd1000000-0000-0000-0000-000000000321', 'd1000000-0000-0000-0000-000000000311',
  'ORDER', 'AWAITING_CUSTOMER', 'WHATSAPP', 'packet-ai-b2b-v1'
);
insert into public.whatsapp_case_identities(
  id, case_id, identity_role, party_type, party_id, resolution_status, phone_e164
) values (
  'd1000000-0000-0000-0000-000000000331', 'd1000000-0000-0000-0000-000000000321',
  'SUBMITTING_SENDER', 'CONTACT', 'd1000000-0000-0000-0000-000000000301', 'SUGGESTED', '919820000011'
);
insert into public.whatsapp_case_recipient_authorizations(
  id, case_id, identity_id, may_receive_clarification, verification_method,
  verified_by, verified_at, correlation_key
) values (
  'd1000000-0000-0000-0000-000000000341', 'd1000000-0000-0000-0000-000000000321',
  'd1000000-0000-0000-0000-000000000331', true, 'PROVENANCE_VERIFIED',
  public.whatsapp_core_c_system_principal_id(), statement_timestamp(),
  'hard:provenance:331'
);
insert into public.whatsapp_case_clarifications(
  id, case_id, field_name, question, recipient_authorization_id, status,
  due_at, next_follow_up_at, asked_by, correlation_key
) values (
  'd1000000-0000-0000-0000-000000000351', 'd1000000-0000-0000-0000-000000000321',
  'QUANTITY', public.wa3_clarification_question('quantity'),
  'd1000000-0000-0000-0000-000000000341', 'OPEN',
  statement_timestamp() + interval '1 day', statement_timestamp() + interval '1 day',
  public.whatsapp_core_c_system_principal_id(), 'hard:clarify:1'
);

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'd1000000-0000-0000-0000-000000000361', 'prov-affirm-ok', '919820000011',
  'ok', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, created_at
) values (
  'd1000000-0000-0000-0000-000000000371', 'd1000000-0000-0000-0000-000000000301',
  'inbound', 'text', 'ok', 'click2api',
  'prov-affirm-ok', 'received', statement_timestamp()
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    'd1000000-0000-0000-0000-000000000301',
    array['d1000000-0000-0000-0000-000000000371'::uuid], 300
  )$$,
  'TEST 1: ambiguous affirmation does not abort stitch transaction'
);
select is(
  (select (public.whatsapp_process_inbound_whatsapp_continuation_v1('d1000000-0000-0000-0000-000000000371')->>'resolved')::boolean),
  false,
  'TEST 1: ambiguous affirmation returns fail-soft unresolved result'
);

-- TEST 2: unresolved blocking reason routes to human review without aborting materialization
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation, model_version
) values (
  'd1000000-0000-0000-0000-000000000411',
  'd1000000-0000-0000-0000-000000000311',
  'fp-hard-unknown', array['prov-affirm-ok'],
  '{"confidence":0.5,"conclusion":{"intent":"ORDER"}}'::jsonb,
  'test-model-v1'
);
insert into public.whatsapp_order_autonomy_decisions(
  id, packet_id, interpretation_id, case_id, potential_order_id,
  autonomy_outcome, blocking_reasons, evaluated_at
) values (
  'd1000000-0000-0000-0000-000000000401',
  'd1000000-0000-0000-0000-000000000311',
  'd1000000-0000-0000-0000-000000000411',
  'd1000000-0000-0000-0000-000000000321',
  null,
  'CLARIFICATION_REQUIRED',
  array['totally_unknown_blocker'],
  statement_timestamp()
);

select is(
  (public.whatsapp_enqueue_autonomy_clarification_v1('d1000000-0000-0000-0000-000000000401')->>'routed_to_human_review')::boolean,
  true,
  'TEST 2: unresolved blocking reason routes to human review'
);
select ok(
  exists(
    select 1 from public.whatsapp_case_events
    where case_id = 'd1000000-0000-0000-0000-000000000321'
      and event_type = 'AUTONOMOUS_CLARIFICATION_BLOCKED'
  ),
  'TEST 2: governed failure evidence recorded'
);

-- TEST 3: non-order routing replay preserves existing human assignment
update public.whatsapp_communication_cases
set case_type = 'COMPLAINT',
    accountable_team = 'QUALITY',
    accountable_owner_id = 'd1000000-0000-0000-0000-000000000001',
    accountability_status = 'ASSIGNED',
    assigned_at = statement_timestamp(),
    assigned_by = 'd1000000-0000-0000-0000-000000000001',
    next_action = 'Operator claimed complaint',
    next_action_due_at = statement_timestamp() + interval '1 day'
where id = 'd1000000-0000-0000-0000-000000000321';

select public.whatsapp_apply_non_order_case_governance_v1(
  'd1000000-0000-0000-0000-000000000321',
  'd1000000-0000-0000-0000-000000000421',
  'COMPLAINT', 'QUALITY'
) as hard_non_order;

select is(
  (select accountable_owner_id from public.whatsapp_communication_cases
    where id = 'd1000000-0000-0000-0000-000000000321'),
  'd1000000-0000-0000-0000-000000000001'::uuid,
  'TEST 3: non-order routing replay preserves human owner'
);
select is(
  (select accountability_status from public.whatsapp_communication_cases
    where id = 'd1000000-0000-0000-0000-000000000321'),
  'ASSIGNED',
  'TEST 3: non-order routing replay preserves ASSIGNED status'
);

select * from finish();
rollback;
