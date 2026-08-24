begin;
-- Adversarial authority closure proofs for 20260824100000_whatsapp_autonomy_core_c_authority_closure.sql
select plan(18);

select has_function('public', 'whatsapp_core_c_system_principal_id', '{}', 'explicit system principal exists');
select has_function('public', 'whatsapp_core_c_classify_outbound_recipient_v1', array['uuid','uuid'], 'recipient classification exists');
select isnt_empty(
  $$select 1 from pg_proc
    where oid = 'public.wa6_guard_operator_reply_disclosure()'::regprocedure
      and pg_get_functiondef(oid) not like '%core_c_governed_outbound%'$$,
  'WA-6 guard has no blanket CORE-C bypass'
);

insert into auth.users (id, email) values
  ('c4000000-0000-0000-0000-000000000001', 'corec-human@example.test'),
  ('c4000000-0000-0000-0000-000000000002', 'corec-employee@example.test'),
  (public.whatsapp_core_c_system_principal_id(), 'whatsapp-autonomous-system@system.oasis.internal');
insert into public.users (id, email, full_name, role, phone) values
  ('c4000000-0000-0000-0000-000000000001', 'corec-human@example.test', 'Human Admin', 'admin', '919820000099'),
  ('c4000000-0000-0000-0000-000000000002', 'corec-employee@example.test', 'Employee Relay', 'sales_executive', '919820000098');
select public.whatsapp_core_c_ensure_system_principal();

insert into public.whatsapp_intelligence_knowledge_snapshots (
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  'c4000000-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{"pista":"BAK-PIST-250"}}'::jsonb,
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  'c4000000-0000-0000-0000-000000000001',
  'c4000000-0000-0000-0000-000000000001', statement_timestamp(),
  'c4000000-0000-0000-0000-000000000001', statement_timestamp()
);
select public.whatsapp_activate_intelligence_knowledge_snapshot('c4000000-0000-0000-0000-000000000010');

insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values (
  'c4000000-0000-0000-0000-000000000101', 'Pistachio Baklawa 250g', 'BAK-PIST-250', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
);
insert into public.product_pricing_rules (
  id, product_id, price_channel, price_type, base_price, calculated_price, uom, approval_status, valid_from
) values (
  'c4000000-0000-0000-0000-000000000161', 'c4000000-0000-0000-0000-000000000101', 'b2b', 'standard', 500.00, 500.00, 'Box', 'approved', current_date - 1
);
insert into public.product_moq_rules (
  id, product_id, channel, moq_applicable, moq_value, moq_uom, increment_value, increment_uom, min_carton_qty
) values (
  'c4000000-0000-0000-0000-000000000171', 'c4000000-0000-0000-0000-000000000101', 'b2b', true, 5, 'Box', 1, 'Box', null
);
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'c4000000-0000-0000-0000-000000000201', 'Taj Sweets Bengaluru', '29ABCDE1234F1Z5', '919820000001', 'credit', 'active', false
);
insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values (
  'c4000000-0000-0000-0000-000000000211', 'c4000000-0000-0000-0000-000000000201',
  'Main Store', '100 MG Road', 'Bengaluru', 'Karnataka', '560001', true
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- TEST 1: automated outbound never attributes random human admin as actor
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c4000000-0000-0000-0000-000000000301', '919820000001', 'Commercial Customer');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c4000000-0000-0000-0000-000000000311', 'prov-auth-ack', '919820000001',
  'Please send 5 boxes BAK-PIST-250', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id, status, created_at
) values (
  'c4000000-0000-0000-0000-000000000321', 'c4000000-0000-0000-0000-000000000301',
  'inbound', 'text', 'Please send 5 boxes BAK-PIST-250', 'click2api', 'prov-auth-ack', 'received', statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic('c4000000-0000-0000-0000-000000000301', array['c4000000-0000-0000-0000-000000000321'::uuid], 300);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c4000000-0000-0000-0000-000000000331',
  (select packet_id from public.whatsapp_messages where id = 'c4000000-0000-0000-0000-000000000321'),
  'fp-auth-ack', array['prov-auth-ack'],
  '{"confidence":0.98,"conclusion":{"intent":"ORDER","summary":"5 boxes","customer":{"company_name":"Taj Sweets Bengaluru","gst_number":"29ABCDE1234F1Z5"},"branch":{"label":"Main Store"},"order_lines":[{"sku":"BAK-PIST-250","product_name":"Pistachio Baklawa 250g","quantity":5,"unit":"box","status":"explicit","evidence_ids":["prov-auth-ack"]}]}}'::jsonb,
  'test-model-v1', 'c4000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  'wa-interpretation/v1', 'wa-packet-policy/v3', 'core-c-autonomy/v1'
);
create temporary table auth_promote as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c4000000-0000-0000-0000-000000000321'),
  'c4000000-0000-0000-0000-000000000331'
) as payload;

select is(
  (select created_by from public.whatsapp_operator_reply_outbox
    where idempotency_key like 'core-c:promoted-ack:%' limit 1),
  public.whatsapp_core_c_system_principal_id(),
  'TEST 1: automated outbound created_by is explicit system principal only'
);
select is(
  (select actor_id from public.whatsapp_operator_reply_events
    where reply_id = (select id from public.whatsapp_operator_reply_outbox where idempotency_key like 'core-c:promoted-ack:%' limit 1)
    order by created_at desc limit 1),
  null,
  'TEST 1: outbound events record actor_id NULL with SYSTEM evidence'
);

-- TEST 2: no automatically generated authorization claims OPERATOR_VERIFIED
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c4000000-0000-0000-0000-000000000401', '919820000002', 'Clarify Customer');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c4000000-0000-0000-0000-000000000411', 'prov-auth-clar', '919820000002',
  'Please send baklawa', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id, status, created_at
) values (
  'c4000000-0000-0000-0000-000000000421', 'c4000000-0000-0000-0000-000000000401',
  'inbound', 'text', 'Please send baklawa', 'click2api', 'prov-auth-clar', 'received', statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic('c4000000-0000-0000-0000-000000000401', array['c4000000-0000-0000-0000-000000000421'::uuid], 300);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c4000000-0000-0000-0000-000000000431',
  (select packet_id from public.whatsapp_messages where id = 'c4000000-0000-0000-0000-000000000421'),
  'fp-auth-clar', array['prov-auth-clar'],
  '{"confidence":0.92,"conclusion":{"intent":"ORDER","summary":"missing quantity","customer":{"company_name":"Taj Sweets Bengaluru","gst_number":"29ABCDE1234F1Z5"},"branch":{"label":"Main Store"},"order_lines":[{"sku":"BAK-PIST-250","product_name":"Pistachio Baklawa 250g","quantity":null,"unit":"box","status":"unclear","evidence_ids":["prov-auth-clar"]}]}}'::jsonb,
  'test-model-v1', 'c4000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  'wa-interpretation/v1', 'wa-packet-policy/v3', 'core-c-autonomy/v1'
);
create temporary table auth_clarify as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c4000000-0000-0000-0000-000000000421'),
  'c4000000-0000-0000-0000-000000000431'
) as payload;

select ok(
  not exists (
    select 1 from public.whatsapp_case_recipient_authorizations a
    where a.case_id = (select (payload->>'case_id')::uuid from auth_clarify)
      and a.verification_method = 'OPERATOR_VERIFIED'
  ),
  'TEST 2: auto-generated authorization never claims OPERATOR_VERIFIED'
);
select is(
  (select verification_method from public.whatsapp_case_recipient_authorizations
    where case_id = (select (payload->>'case_id')::uuid from auth_clarify)
      and correlation_key like 'core-c:provenance:%'),
  'PROVENANCE_VERIFIED',
  'TEST 2: clarification eligibility uses PROVENANCE_VERIFIED'
);

-- TEST 3/6: employee relay classified distinctly and receives internal-safe ack
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c4000000-0000-0000-0000-000000000501', '919820000098', 'Employee Relay Contact');
select is(
  (public.whatsapp_core_c_classify_outbound_recipient_v1('c4000000-0000-0000-0000-000000000501')->>'recipient_class'),
  'EMPLOYEE_RELAY',
  'TEST 3: employee relay contact is classified distinctly'
);
select is(
  (public.whatsapp_core_c_resolve_promoted_ack_payload('c4000000-0000-0000-0000-000000000501', null, 'SO-EMP-001')->>'order_reference_included')::boolean,
  false,
  'TEST 6: employee relay ack excludes commercial SO reference'
);

-- TEST 4/5: unknown vs verified commercial disclosure for promoted ack
select is(
  (public.whatsapp_core_c_classify_outbound_recipient_v1('c4000000-0000-0000-0000-000000000301')->>'recipient_class'),
  'UNKNOWN_EXTERNAL',
  'TEST 4: unknown external sender has no commercial disclosure class'
);
select is(
  (public.whatsapp_core_c_resolve_promoted_ack_payload('c4000000-0000-0000-0000-000000000301', null, 'SO-EXT-001')->>'order_reference_included')::boolean,
  false,
  'TEST 4: unknown external sender cannot receive SO/order-reference disclosure'
);

select set_config('request.jwt.claims', json_build_object('sub','c4000000-0000-0000-0000-000000000001','role','service_role','aal','aal2')::text, true);
select public.authorize_whatsapp_commercial_disclosure(
  'c4000000-0000-0000-0000-000000000301',
  'c4000000-0000-0000-0000-000000000201',
  array['sales_order'],
  '{"method":"verified_account_contact"}',
  statement_timestamp() + interval '30 days'
);
select set_config('app.wa3_governed_mutation', 'on', true);
insert into public.whatsapp_order_field_resolutions(
  potential_order_id, field_key, resolution_state, resolved_value, resolved_at, resolved_by
)
select potential_order_id, 'client_identity', 'operator_confirmed',
  '{"company_id":"c4000000-0000-0000-0000-000000000201"}', statement_timestamp(),
  'c4000000-0000-0000-0000-000000000001'
from public.whatsapp_order_autonomy_decisions
where id = (select (payload->>'autonomy_decision_id')::uuid from auth_promote);
select set_config('app.wa3_governed_mutation', 'off', true);
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

select is(
  (public.whatsapp_core_c_classify_outbound_recipient_v1(
    'c4000000-0000-0000-0000-000000000301',
    (select potential_order_id from public.whatsapp_order_autonomy_decisions
      where id = (select (payload->>'autonomy_decision_id')::uuid from auth_promote))
  )->>'recipient_class'),
  'VERIFIED_COMMERCIAL_CUSTOMER',
  'TEST 5: verified commercial recipient class is distinct from employee relay'
);
select ok(
  (public.whatsapp_core_c_resolve_promoted_ack_payload(
    'c4000000-0000-0000-0000-000000000301',
    (select potential_order_id from public.whatsapp_order_autonomy_decisions
      where id = (select (payload->>'autonomy_decision_id')::uuid from auth_promote)),
    'SO-VER-001'
  )->>'order_reference_included')::boolean,
  'TEST 5: verified commercial recipient may receive governed SO acknowledgement'
);

-- TEST 7: clarification to submitting sender without commercial scope
select is(
  (select may_confirm_commercial_scope from public.whatsapp_case_recipient_authorizations
    where case_id = (select (payload->>'case_id')::uuid from auth_clarify)
      and correlation_key like 'core-c:provenance:%'),
  false,
  'TEST 7: provenance authorization does not grant commercial scope'
);
select is(
  (select disclosure_scope from public.whatsapp_case_recipient_authorizations
    where case_id = (select (payload->>'case_id')::uuid from auth_clarify)
      and correlation_key like 'core-c:provenance:%'),
  '{}'::text[],
  'TEST 7: provenance authorization keeps disclosure scope empty'
);

-- TEST 8: team routing without fictitious owner
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c4000000-0000-0000-0000-000000000601', '919820000003', 'Complaint Customer');
insert into public.whatsapp_inbound_messages(id, provider_message_id, sender_phone, message_body, message_type, received_at)
values ('c4000000-0000-0000-0000-000000000611', 'prov-complaint', '919820000003', 'Product was stale', 'text', statement_timestamp());
insert into public.whatsapp_messages(id, contact_id, direction, message_type, content, provider, provider_message_id, status, created_at)
values ('c4000000-0000-0000-0000-000000000621', 'c4000000-0000-0000-0000-000000000601', 'inbound', 'text', 'Product was stale', 'click2api', 'prov-complaint', 'received', statement_timestamp());
select public.stitch_whatsapp_messages_atomic('c4000000-0000-0000-0000-000000000601', array['c4000000-0000-0000-0000-000000000621'::uuid], 300);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c4000000-0000-0000-0000-000000000631',
  (select packet_id from public.whatsapp_messages where id = 'c4000000-0000-0000-0000-000000000621'),
  'fp-complaint', array['prov-complaint'],
  '{"confidence":0.95,"conclusion":{"intent":"COMPLAINT","summary":"stale product","primary_department":"QUALITY"}}'::jsonb,
  'test-model-v1', 'c4000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  'wa-interpretation/v1', 'wa-packet-policy/v3', 'core-c-autonomy/v1'
);
create temporary table auth_complaint as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c4000000-0000-0000-0000-000000000621'),
  'c4000000-0000-0000-0000-000000000631'
) as payload;

select is(
  (select accountable_team from public.whatsapp_communication_cases
    where id = (select (payload->>'case_id')::uuid from auth_complaint)),
  'QUALITY',
  'TEST 8: automatic routing sets accountable_team'
);
select ok(
  (select accountable_owner_id is null
    and accountability_status = 'UNASSIGNED'
    and assigned_by is null
   from public.whatsapp_communication_cases
   where id = (select (payload->>'case_id')::uuid from auth_complaint)),
  'TEST 8: automatic routing does not assign fictitious human owner'
);

-- TEST 9: non-order governance ignores AI reply_clearance (structural proof)
select isnt_empty(
  $$select 1 from pg_proc
    where oid = 'public.whatsapp_apply_non_order_case_governance_v1(uuid,uuid,text,text,text,text)'::regprocedure
      and pg_get_functiondef(oid) not like '%SAFE_TO_SEND_AUTOMATICALLY%'$$,
  'TEST 9: non-order receipt policy is deterministic and not AI-reply_clearance gated'
);

-- TEST 10: quantity clarification uses WA-3 template, not unrelated AI text
select is(
  (select question from public.whatsapp_case_clarifications
    where case_id = (select (payload->>'case_id')::uuid from auth_clarify)),
  public.wa3_clarification_question('quantity'),
  'TEST 10: quantity clarification asks WA-3 quantity question only'
);

-- TEST 11: unknown blocking reason fails closed
select throws_ok(
  $$select public.whatsapp_core_c_derive_clarification_field(array['totally_unknown_blocker'])::text$$,
  'CORE_C_UNRESOLVED_BLOCKING_REASON',
  'TEST 11: unknown blocking reason does not default to product question'
);

-- TEST 12/13: human paths remain intact
select has_function('public', 'whatsapp_confirm_clarification_answer', array['uuid','text','text'], 'human clarification authority remains');
select has_function('public', 'authorize_whatsapp_commercial_disclosure', array['uuid','uuid','text[]','jsonb','timestamp with time zone'], 'WA-6 operator disclosure authority remains');

-- TEST 14: replay/idempotency still prevents duplicate outbound
select lives_ok(
  $$select public.whatsapp_enqueue_promoted_order_acknowledgement_v1(
    (select (payload->>'autonomy_decision_id')::uuid from auth_promote), 'SO-VER-001'
  )$$,
  'TEST 14: promoted acknowledgement replay is idempotent'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where idempotency_key = 'core-c:promoted-ack:' || (select payload->>'autonomy_decision_id' from auth_promote)),
  1,
  'TEST 14: replay retains exactly one outbound row'
);

select * from finish();
rollback;
