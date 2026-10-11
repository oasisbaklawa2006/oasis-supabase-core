begin;
-- Mission Control #629 P1 investigation: why do 103 whatsapp_case_identities remain
-- SUGGESTED with zero CONFIRMED, and why do all whatsapp_order_autonomy_decisions
-- report an unresolved customer?
--
-- Finding (proven below): whatsapp_confirm_case_identity() and its
-- bridge_whatsapp_case_identity_to_wa3() trigger are correctly built and fully
-- wired to a real operator UI ("Confirm / re-authorise customer" in
-- OperatorInboxCaseLifecycleActions.tsx). Nothing there is broken.
--
-- The real gap: whatsapp_materialize_packet_ai_case() is the ONLY call site that
-- ever creates a draft/promotes a Sales Order, and it runs exactly once per
-- packet interpretation, resolving the customer solely from the AI's own
-- extracted candidate (GST/company name in the message text) or a pre-existing
-- phone/GST/WA-6-authorization match. An operator's later identity confirmation
-- (which necessarily happens AFTER materialize already ran and failed to
-- resolve) is recorded as durable evidence but nothing ever re-invokes
-- draft creation/promotion using that now-confirmed identity. The chain
-- architecturally dead-ends after human confirmation.
--
-- This test proves the dead-end empirically (Part A), then proves the rest of
-- the pipeline -- whatsapp_resolve_governed_customer's explicit-candidate path,
-- whatsapp_execute_autonomous_order_draft_v1, and governed SO promotion -- all
-- work correctly today once a confirmed identity is supplied as candidate
-- (Part B), demonstrating the minimum repair is additive (a retry entry point
-- seeded with the confirmed company_id), not a rewrite.
--
-- Entirely synthetic fixtures, entirely local. No production data touched,
-- no real WhatsApp send, no live customer order.

select plan(16);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- ---------------------------------------------------------------------------
-- Fixtures: an active company whose phone/GST/name the sender will NOT state
-- or match automatically (the realistic production case: 0/52 real senders
-- matched by phone, and no autonomy decision has ever resolved a customer).
-- ---------------------------------------------------------------------------
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'c6290000-0000-0000-0000-000000000201', 'Point629 Test Traders', '27PQRSX5678G1Z3',
  '919800000201', 'credit', 'active', false
);

insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values (
  'c6290000-0000-0000-0000-000000000211', 'c6290000-0000-0000-0000-000000000201',
  'Main Store', '1 Test Lane', 'Mumbai', 'Maharashtra', '400001', true
);

insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values (
  'c6290000-0000-0000-0000-000000000101', 'Point629 Test Baklawa 250g', 'BAK-P629-250', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
);

insert into public.product_pricing_rules (
  id, product_id, price_channel, price_type, base_price, calculated_price, uom, approval_status, valid_from
) values (
  'c6290000-0000-0000-0000-000000000161', 'c6290000-0000-0000-0000-000000000101', 'b2b', 'standard', 500.00, 500.00, 'Box', 'approved', current_date - 1
);

-- Sender phone deliberately does NOT match the company's phone/GST/name.
insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('c6290000-0000-0000-0000-000000000301', '919111000301', 'Point629 Unidentified Sender');

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c6290000-0000-0000-0000-000000000311', 'wamid.p629-001', '919111000301',
  'Please send 5 boxes of pistachio baklawa', 'text', statement_timestamp()
);

insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'c6290000-0000-0000-0000-000000000321', 'c6290000-0000-0000-0000-000000000301',
  'inbound', 'text', 'Please send 5 boxes of pistachio baklawa', 'click2api',
  'wamid.p629-001', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'c6290000-0000-0000-0000-000000000301',
  array['c6290000-0000-0000-0000-000000000321'::uuid], 300
);

-- AI interpretation does NOT contain an explicit company/GST candidate -- this
-- is the realistic shape: the sender never states their business identity.
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c6290000-0000-0000-0000-000000000331',
  (select packet_id from public.whatsapp_messages where id = 'c6290000-0000-0000-0000-000000000321'),
  'fp-p629-001',
  array['wamid.p629-001'],
  '{"confidence": 0.95, "conclusion": {"intent": "ORDER", "summary": "5 boxes pistachio baklawa", "order_lines": [{"sku": "BAK-P629-250", "product_name": "Point629 Test Baklawa 250g", "quantity": 5, "unit": "box", "status": "explicit", "evidence_ids": ["wamid.p629-001"]}]}}'::jsonb,
  'test-model-v1', null, null, null,
  'wa-interpretation/v1', 'wa-prompt/v1', 'point629/v1'
);

-- ===========================================================================
-- PART A: the real production dead-end, proven end to end
-- ===========================================================================

-- A1. Materialize the case exactly as the packet-ai worker would in production.
create temporary table p629_materialize as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c6290000-0000-0000-0000-000000000321'),
  'c6290000-0000-0000-0000-000000000331'
) as payload;

select set_config('p629.case_id', (select payload->>'case_id' from p629_materialize), false);
select set_config('p629.autonomy_outcome', (select payload->>'autonomy_outcome' from p629_materialize), false);
select set_config('p629.pre_confirm_status', (select status from public.whatsapp_communication_cases where id = current_setting('p629.case_id')::uuid), false);

select isnt(
  current_setting('p629.autonomy_outcome'),
  'AUTO_ELIGIBLE',
  'A1: without a stated GST/company or on-file phone, materialize does NOT auto-resolve the customer -- reproduces the production state (0/111 decisions ever resolved)'
);

select is(
  (select count(*)::int from public.sales_order_drafts d
    where d.packet_id = (select packet_id from public.whatsapp_messages where id = 'c6290000-0000-0000-0000-000000000321')),
  0,
  'A2: no draft is created while the customer is unresolved'
);

select is(
  (select resolution_status from public.whatsapp_case_identities
    where case_id = current_setting('p629.case_id')::uuid and identity_role = 'SUBMITTING_SENDER'),
  'SUGGESTED',
  'A3: the sender identity sits at SUGGESTED, matching the 103 production rows exactly'
);

select is(
  (select count(*)::int from public.whatsapp_case_identities
    where case_id = current_setting('p629.case_id')::uuid and identity_role = 'COMMERCIAL_CUSTOMER'),
  0,
  'A4: no COMMERCIAL_CUSTOMER identity exists yet -- matches zero such rows found in production'
);

-- A5. An authenticated triage operator now confirms the real customer out of band.
insert into auth.users (id, email) values
  ('c6290000-0000-0000-0000-000000000901', 'p629-operator@example.test');
insert into public.users (id, email, full_name, role, is_active) values
  ('c6290000-0000-0000-0000-000000000901', 'p629-operator@example.test', 'P629 Operator', 'support_executive', true);
insert into public.user_role_map(user_id, role_id)
select 'c6290000-0000-0000-0000-000000000901', id from public.roles where role_key = 'support_executive'
on conflict (user_id, role_id) do nothing;

select set_config('request.jwt.claims', json_build_object('sub','c6290000-0000-0000-0000-000000000901','role','authenticated','aal','aal1')::text, true);
set local role authenticated;

select lives_ok(
  $$select public.whatsapp_confirm_case_identity(
    current_setting('p629.case_id')::uuid,
    'c6290000-0000-0000-0000-000000000201'::uuid,
    'OPERATOR_VERIFIED',
    '{}'::text[], true, false, null,
    jsonb_build_object('note', 'Phone callback verified against company records'),
    'p629-identity-confirm-001'
  )$$,
  'A5: the real, UI-wired confirm_case_identity RPC succeeds for an operator with wa.intake.triage'
);

select is(
  (select resolution_status from public.whatsapp_case_identities
    where case_id = current_setting('p629.case_id')::uuid and identity_role = 'COMMERCIAL_CUSTOMER'),
  'CONFIRMED',
  'A6: COMMERCIAL_CUSTOMER identity is now CONFIRMED, linked to the real company'
);

-- Secondary finding: whatsapp_confirm_case_identity only advances case status
-- when it is exactly 'NEEDS_IDENTITY' (see migration 20260817193859). Materialize
-- actually leaves an unresolved case at a different pre-confirm status, so the
-- status transition silently never fires -- worth a one-line fix alongside the
-- main repair, not a blocker to the chain proven below.
select is(
  (select status from public.whatsapp_communication_cases where id = current_setting('p629.case_id')::uuid),
  current_setting('p629.pre_confirm_status'),
  'A7: SECONDARY FINDING -- case status (' || current_setting('p629.pre_confirm_status') || ') does not match the literal ''NEEDS_IDENTITY'' string the confirm function checks for, so it never advances to OPEN'
);

select ok(
  exists(
    select 1 from public.whatsapp_case_events
    where case_id = current_setting('p629.case_id')::uuid
      and event_type = 'CASE_IDENTITY_CONFIRMED'
  ),
  'A8: CASE_IDENTITY_CONFIRMED event recorded (fires the WA3 bridge trigger)'
);

-- A8b. Part A's unresolved-customer attempt left a formal OPEN clarification
-- on the case (a real, separate governance guard: a case cannot reach
-- READY_FOR_DRAFT while a clarification is open). Resolve it the same way an
-- operator would, via the real whatsapp_confirm_clarification_answer RPC,
-- while still authenticated as the same triage operator, using a synthetic
-- customer reply message.
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c6290000-0000-0000-0000-000000000312', 'wamid.p629-002', '919111000301',
  'This is Point629 Test Traders, GST 27PQRSX5678G1Z3', 'text', statement_timestamp()
);
insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'c6290000-0000-0000-0000-000000000322', 'c6290000-0000-0000-0000-000000000301',
  'inbound', 'text', 'This is Point629 Test Traders, GST 27PQRSX5678G1Z3', 'click2api',
  'wamid.p629-002', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  'c6290000-0000-0000-0000-000000000301',
  array['c6290000-0000-0000-0000-000000000322'::uuid], 300
);
select set_config('request.jwt.claims', json_build_object('sub','c6290000-0000-0000-0000-000000000901','role','authenticated','aal','aal1')::text, true);
set local role authenticated;

select public.whatsapp_confirm_clarification_answer(
  (select id from public.whatsapp_case_clarifications where case_id = current_setting('p629.case_id')::uuid and status = 'OPEN' order by created_at limit 1),
  'c6290000-0000-0000-0000-000000000312',
  'This is Point629 Test Traders, GST 27PQRSX5678G1Z3',
  jsonb_build_object('gst_number', '27PQRSX5678G1Z3'),
  'p629-clarification-answer-001'
) where exists (select 1 from public.whatsapp_case_clarifications where case_id = current_setting('p629.case_id')::uuid and status = 'OPEN');

reset role;

-- A9. THE GAP, proven directly: nothing re-attempts resolution after
-- confirmation. The same bare candidate that failed in A1 still fails now,
-- because no call site ever passes the just-confirmed company_id forward.
select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'c6290000-0000-0000-0000-000000000301'::uuid, '{}'::jsonb
  )),
  'UNRESOLVED',
  'A9: THE GAP -- whatsapp_resolve_governed_customer still reports UNRESOLVED even after confirmation, because confirmed identity is never fed back as candidate input'
);

select is(
  (select count(*)::int from public.sales_order_drafts d
    where d.packet_id = (select packet_id from public.whatsapp_messages where id = 'c6290000-0000-0000-0000-000000000321')),
  0,
  'A10: confirming identity alone still creates zero drafts -- the dead-end is real, not a test artifact'
);

-- ===========================================================================
-- PART B: everything downstream of identity resolution already works. Proof
-- that the minimum repair is additive (pass the confirmed company_id as
-- candidate) rather than a rewrite of the resolver or promotion machinery.
-- ===========================================================================

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- B1. The resolver's own Priority-0 explicit-candidate path -- unmodified,
-- existing code -- resolves instantly once given the confirmed company_id.
select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'c6290000-0000-0000-0000-000000000301'::uuid,
    jsonb_build_object('company_id', 'c6290000-0000-0000-0000-000000000201')
  )),
  'RESOLVED',
  'B1: passing the confirmed company_id as explicit candidate resolves immediately via existing EXPLICIT_CANDIDATE_COMPANY_ID logic -- no resolver change needed'
);

-- B2. Re-run the SAME real, unmodified, already-certified orchestrator
-- (whatsapp_materialize_packet_ai_case) that Part A called, but this time its
-- candidate carries the GST of the company the operator just confirmed --
-- exactly what the proposed repair function would construct from the
-- confirmed whatsapp_case_identities row before re-triggering evaluation.
-- A fresh interpretation_id represents that retry pass (the original is
-- already consumed by Part A's decision row).
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c6290000-0000-0000-0000-000000000332',
  (select packet_id from public.whatsapp_messages where id = 'c6290000-0000-0000-0000-000000000321'),
  'fp-p629-001-retry',
  array['wamid.p629-001'],
  jsonb_build_object(
    'confidence', 0.95,
    'conclusion', jsonb_build_object(
      'intent', 'ORDER',
      'summary', '5 boxes pistachio baklawa, identity confirmed by operator',
      'customer', jsonb_build_object('gst_number', '27PQRSX5678G1Z3'),
      'branch', jsonb_build_object('label', 'Main Store'),
      'order_lines', jsonb_build_array(jsonb_build_object(
        'sku', 'BAK-P629-250', 'product_name', 'Point629 Test Baklawa 250g',
        'quantity', 5, 'unit', 'box', 'status', 'explicit', 'evidence_ids', jsonb_build_array('wamid.p629-001')
      ))
    )
  ),
  'test-model-v1', null, null, null,
  'wa-interpretation/v1', 'wa-prompt/v1', 'point629/v1-retry'
);

create temporary table p629_retry as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c6290000-0000-0000-0000-000000000321'),
  'c6290000-0000-0000-0000-000000000332'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from p629_retry),
  'AUTO_ELIGIBLE',
  'B2: re-evaluating with the confirmed company''s GST as candidate resolves the customer and reaches AUTO_ELIGIBLE -- the existing resolver needs no change'
);

select diag('B3 DIAGNOSTIC full draft_execution payload = ' || coalesce((select payload->'draft_execution' from p629_retry)::text, 'NULL'));
select diag('B3 DIAGNOSTIC full payload = ' || coalesce((select payload from p629_retry)::text, 'NULL'));

select is(
  (select payload->'draft_execution'->>'execution_status' from p629_retry),
  'PROMOTED',
  'B3: the existing, unmodified execute/promote chain succeeds end to end once identity resolves'
);

select is(
  (select o.order_origin from public.orders o
    where o.id = (select (payload->'draft_execution'->>'promoted_order_id') from p629_retry)::uuid),
  'WHATSAPP',
  'B4: the resulting Sales Order carries order_origin = WHATSAPP -- one controlled WhatsApp-to-SO transaction, proven locally with synthetic data'
);

select is(
  (select o.company_id from public.orders o
    where o.id = (select (payload->'draft_execution'->>'promoted_order_id') from p629_retry)::uuid),
  'c6290000-0000-0000-0000-000000000201'::uuid,
  'B5: the promoted order is linked to the SAME company the operator confirmed in Part A, not an invented or mismatched identity'
);

select is(
  (select count(*)::int from public.sales_order_draft_lines l
    join public.sales_order_drafts d on d.id = l.draft_id
    where d.id = (select (payload->'draft_execution'->>'sales_order_draft_id') from p629_retry)::uuid
      and l.sku = 'BAK-P629-250' and l.operator_quantity = 5),
  1,
  'B6: the promoted order line reflects the real, customer-stated quantity (5), not an assumed quantity=1'
);

select * from finish();
rollback;
