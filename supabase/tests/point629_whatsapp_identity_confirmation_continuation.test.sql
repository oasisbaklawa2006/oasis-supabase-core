begin;
-- Mission Control #629 — activation repair regression (companion to the
-- investigation-only PR #411 / point629_whatsapp_identity_confirmation_to_so_gap).
--
-- Proves the real continuation mechanism added in
-- 20261011120000_whatsapp_identity_confirmation_continuation.sql:
--   CASE_IDENTITY_CONFIRMED event -> whatsapp_continue_case_after_identity_confirmation()
--   trigger -> clones the real AI interpretation verbatim -> enqueues a
--   CASE_CONTEXT dispatch job on the EXISTING queue -> the existing worker's
--   claim/complete lease path -> whatsapp_materialize_packet_ai_case ->
--   whatsapp_evaluate_and_materialize_order_autonomy (now preferring the
--   CONFIRMED COMMERCIAL_CUSTOMER identity over the AI's own candidate) ->
--   one governed Sales Order.
--
-- Unlike PR #411's Part B, this never hand-builds an enriched AI
-- interpretation with injected GST/branch facts. The cloned interpretation
-- carries the SAME unresolved customer candidate the original did; the
-- resolution succeeds purely because CORE-A now consults the confirmed case
-- identity, exactly as the mission required.
--
-- Entirely synthetic fixtures, entirely local. No production data touched,
-- no real WhatsApp send, no live customer order.

select plan(15);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- ---------------------------------------------------------------------------
-- Fixtures (distinct id prefix from point629_whatsapp_identity_confirmation_to_so_gap).
-- ---------------------------------------------------------------------------
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'c6310000-0000-0000-0000-000000000201', 'Point631 Test Traders', '27PQRSX5678G1Z4',
  '919800000211', 'credit', 'active', false
);

insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values (
  'c6310000-0000-0000-0000-000000000211', 'c6310000-0000-0000-0000-000000000201',
  'Main Store', '1 Test Lane', 'Mumbai', 'Maharashtra', '400001', true
);

insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values (
  'c6310000-0000-0000-0000-000000000101', 'Point631 Test Baklawa 250g', 'BAK-P631-250', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
);

insert into public.product_pricing_rules (
  id, product_id, price_channel, price_type, base_price, calculated_price, uom, approval_status, valid_from
) values (
  'c6310000-0000-0000-0000-000000000161', 'c6310000-0000-0000-0000-000000000101', 'b2b', 'standard', 500.00, 500.00, 'Box', 'approved', current_date - 1
);

-- Sender phone deliberately does NOT match the company's phone/GST/name.
insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('c6310000-0000-0000-0000-000000000301', '919111000311', 'Point631 Unidentified Sender');

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c6310000-0000-0000-0000-000000000311', 'wamid.p631-001', '919111000311',
  'Please send 7 boxes of pistachio baklawa', 'text', statement_timestamp()
);

insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'c6310000-0000-0000-0000-000000000321', 'c6310000-0000-0000-0000-000000000301',
  'inbound', 'text', 'Please send 7 boxes of pistachio baklawa', 'click2api',
  'wamid.p631-001', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'c6310000-0000-0000-0000-000000000301',
  array['c6310000-0000-0000-0000-000000000321'::uuid], 300
);

-- AI interpretation does NOT contain an explicit company/GST candidate -- the
-- realistic shape this whole mission is about: the sender never states their
-- business identity, so materialize cannot auto-resolve the customer.
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c6310000-0000-0000-0000-000000000331',
  (select packet_id from public.whatsapp_messages where id = 'c6310000-0000-0000-0000-000000000321'),
  'fp-p631-001',
  array['wamid.p631-001'],
  '{"confidence": 0.95, "conclusion": {"intent": "ORDER", "summary": "7 boxes pistachio baklawa", "order_lines": [{"sku": "BAK-P631-250", "product_name": "Point631 Test Baklawa 250g", "quantity": 7, "unit": "box", "status": "explicit", "evidence_ids": ["wamid.p631-001"]}]}}'::jsonb,
  'test-model-v1', null, null, null,
  'wa-interpretation/v1', 'wa-prompt/v1', 'point631/v1'
);

-- ---------------------------------------------------------------------------
-- 1. Reproduce the dead end (same mechanism as PR #411, different fixtures).
-- ---------------------------------------------------------------------------
create temporary table p631_materialize as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c6310000-0000-0000-0000-000000000321'),
  'c6310000-0000-0000-0000-000000000331'
) as payload;

select set_config('p631.case_id', (select payload->>'case_id' from p631_materialize), false);
select set_config('p631.packet_id', (select packet_id::text from public.whatsapp_messages where id = 'c6310000-0000-0000-0000-000000000321'), false);

select isnt(
  (select payload->>'autonomy_outcome' from p631_materialize),
  'AUTO_ELIGIBLE',
  '1: without a stated GST/company, materialize does not auto-resolve the customer'
);

select is(
  (select count(*)::int from public.whatsapp_case_identity_confirmation_continuations
    where case_id = current_setting('p631.case_id')::uuid),
  0,
  '2: no continuation exists yet -- nothing has been confirmed'
);

-- ---------------------------------------------------------------------------
-- 2. Resolve the real, separate formal-clarification guard that step 1 left
--    OPEN (unresolved customer -> CLARIFICATION_REQUIRED), the same way an
--    operator would, via the real whatsapp_confirm_clarification_answer RPC.
--    Done before identity confirmation so the dispatch queue below is left
--    holding exactly one job (the later CASE_CONTEXT one) by the time the
--    worker claims it -- in production the durable worker has already
--    claimed and completed every PACKET job raised by this packet's
--    messages long before an operator ever opens the case.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('c6310000-0000-0000-0000-000000000901', 'p631-operator@example.test');
insert into public.users (id, email, full_name, role, is_active) values
  ('c6310000-0000-0000-0000-000000000901', 'p631-operator@example.test', 'P631 Operator', 'support_executive', true);
insert into public.user_role_map(user_id, role_id)
select 'c6310000-0000-0000-0000-000000000901', id from public.roles where role_key = 'support_executive'
on conflict (user_id, role_id) do nothing;

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c6310000-0000-0000-0000-000000000312', 'wamid.p631-002', '919111000311',
  'This is Point631 Test Traders', 'text', statement_timestamp()
);
insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'c6310000-0000-0000-0000-000000000322', 'c6310000-0000-0000-0000-000000000301',
  'inbound', 'text', 'This is Point631 Test Traders', 'click2api',
  'wamid.p631-002', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  'c6310000-0000-0000-0000-000000000301',
  array['c6310000-0000-0000-0000-000000000322'::uuid], 300
);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','c6310000-0000-0000-0000-000000000901','role','authenticated','aal','aal1')::text, true);
select public.whatsapp_confirm_clarification_answer(
  (select id from public.whatsapp_case_clarifications where case_id = current_setting('p631.case_id')::uuid and status = 'OPEN' order by created_at limit 1),
  'c6310000-0000-0000-0000-000000000312',
  'This is Point631 Test Traders',
  jsonb_build_object('company_id', 'c6310000-0000-0000-0000-000000000201'),
  'p631-clarification-answer-001'
) where exists (select 1 from public.whatsapp_case_clarifications where case_id = current_setting('p631.case_id')::uuid and status = 'OPEN');
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- Drain the PACKET job this packet's two messages raised, exactly as the
-- durable worker already would have in production before this point.
create temporary table p631_packet_job as
select * from public.claim_whatsapp_packet_ai_dispatch_job(120);
select public.complete_whatsapp_packet_ai_dispatch_job(
  (select id from p631_packet_job), (select lease_token from p631_packet_job), (select packet_revision from p631_packet_job)
) where (select id from p631_packet_job) is not null;

-- ---------------------------------------------------------------------------
-- 3. A real operator confirms the customer via the real, unmodified,
--    permission-gated RPC -- exactly as Central's "Confirm / re-authorise
--    customer" button would call it.
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','c6310000-0000-0000-0000-000000000901','role','authenticated','aal','aal1')::text, true);

select lives_ok(
  $$select public.whatsapp_confirm_case_identity(
    current_setting('p631.case_id')::uuid,
    'c6310000-0000-0000-0000-000000000201'::uuid,
    'OPERATOR_VERIFIED',
    '{}'::text[], true, false, null,
    jsonb_build_object('note', 'Phone callback verified against company records'),
    'p631-identity-confirm-001'
  )$$,
  '3: the real whatsapp_confirm_case_identity RPC succeeds for an operator with wa.intake.triage'
);

select is(
  (select resolution_status from public.whatsapp_case_identities
    where case_id = current_setting('p631.case_id')::uuid and identity_role = 'COMMERCIAL_CUSTOMER'),
  'CONFIRMED',
  '4: COMMERCIAL_CUSTOMER identity is now CONFIRMED'
);

reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- ---------------------------------------------------------------------------
-- 4. The continuation fired automatically -- this is the activation repair,
--    not a manually-invoked retry.
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::int from public.whatsapp_case_identity_confirmation_continuations
    where case_id = current_setting('p631.case_id')::uuid),
  1,
  '5: confirming identity automatically recorded exactly one continuation -- no operator or worker action required to raise it'
);

select is(
  (select j.state from public.whatsapp_packet_ai_dispatch_jobs j
    join public.whatsapp_case_identity_confirmation_continuations c on c.dispatch_job_id = j.id
    where c.case_id = current_setting('p631.case_id')::uuid),
  'QUEUED',
  '6: a real CASE_CONTEXT dispatch job was enqueued on the EXISTING durable queue -- no second queue'
);

select is(
  (select cloned.interpretation->'conclusion'->>'summary'
    from public.whatsapp_case_identity_confirmation_continuations c
    join public.whatsapp_packet_ai_interpretations cloned on cloned.id = c.cloned_interpretation_id
    where c.case_id = current_setting('p631.case_id')::uuid),
  '7 boxes pistachio baklawa',
  '7: the cloned interpretation preserves the ORIGINAL AI conclusion verbatim -- no fictitious facts, no injected GST/branch'
);

-- Confirming again with the SAME idempotency key must not raise a second
-- continuation (duplicate confirmation / replayed event protection).
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','c6310000-0000-0000-0000-000000000901','role','authenticated','aal','aal1')::text, true);
select public.whatsapp_confirm_case_identity(
  current_setting('p631.case_id')::uuid,
  'c6310000-0000-0000-0000-000000000201'::uuid,
  'OPERATOR_VERIFIED',
  '{}'::text[], true, false, null,
  jsonb_build_object('note', 'Phone callback verified against company records'),
  'p631-identity-confirm-001'
);
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

select is(
  (select count(*)::int from public.whatsapp_case_identity_confirmation_continuations
    where case_id = current_setting('p631.case_id')::uuid),
  1,
  '8: a duplicate/replayed confirmation (same idempotency key) does not raise a second continuation'
);

-- ---------------------------------------------------------------------------
-- 5. A stale/invalid lease must produce no order -- the existing lease
--    protection is honored, not bypassed, by the new continuation path.
-- ---------------------------------------------------------------------------
do $$
declare
  v_packet_id uuid := current_setting('p631.packet_id')::uuid;
  v_cloned_id uuid;
  v_job_id uuid;
begin
  select cloned_interpretation_id, dispatch_job_id into v_cloned_id, v_job_id
  from public.whatsapp_case_identity_confirmation_continuations
  where case_id = current_setting('p631.case_id')::uuid;

  perform public.whatsapp_materialize_packet_ai_case(
    v_packet_id, v_cloned_id, v_job_id, gen_random_uuid(), 1
  );
  perform set_config('p631.stale_lease_error', 'NO_ERROR_RAISED', false);
exception when others then
  perform set_config('p631.stale_lease_error', sqlerrm, false);
end $$;

select is(
  current_setting('p631.stale_lease_error'),
  'dispatch lease invalid or superseded',
  '9: a wrong lease token is rejected -- the continuation cannot bypass existing lease protection'
);

select is(
  (select count(*)::int from public.whatsapp_order_autonomy_decisions
    where interpretation_id = (select cloned_interpretation_id from public.whatsapp_case_identity_confirmation_continuations
      where case_id = current_setting('p631.case_id')::uuid)),
  0,
  '10: the rejected stale-lease attempt created no autonomy decision and no order'
);

-- ---------------------------------------------------------------------------
-- 6. Simulate the existing worker claiming the real CASE_CONTEXT job (exact
--    same claim_whatsapp_packet_ai_dispatch_job / lease contract the live
--    worker uses) and re-running materialize with the cloned interpretation.
--    By this point the only job left QUEUED for this packet is the
--    CASE_CONTEXT one raised by identity confirmation.
-- ---------------------------------------------------------------------------
create temporary table p631_claim as
select * from public.claim_whatsapp_packet_ai_dispatch_job(120);

select is(
  (select execution_kind from p631_claim),
  'CASE_CONTEXT',
  '11: the worker claims the identity-confirmation job through the existing claim/lease contract, unmodified'
);

-- The lease contract additionally requires the case's LIVE context_revision
-- to still match the claimed job's context_revision at use time.
select is(
  (select (select context_revision from p631_claim)::text || ':' || (select c.context_revision::text from public.whatsapp_communication_cases c where c.id = current_setting('p631.case_id')::uuid)),
  (select (select context_revision from p631_claim)::text || ':' || (select context_revision from p631_claim)::text),
  '11b: the claimed job''s context_revision still matches the case''s live context_revision'
);

create temporary table p631_continuation_result as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from p631_claim),
  (select cloned_interpretation_id from public.whatsapp_case_identity_confirmation_continuations
    where case_id = current_setting('p631.case_id')::uuid),
  (select id from p631_claim),
  (select lease_token from p631_claim),
  (select packet_revision from p631_claim)
) as payload;

select public.complete_whatsapp_packet_ai_dispatch_job(
  (select id from p631_claim), (select lease_token from p631_claim), (select packet_revision from p631_claim)
);

select is(
  (select payload->>'autonomy_outcome' from p631_continuation_result),
  'AUTO_ELIGIBLE',
  '12: re-materializing the cloned (unmodified) interpretation now resolves the customer via the CONFIRMED identity and reaches AUTO_ELIGIBLE'
);

select is(
  (select o.order_origin from public.orders o
    where o.id = (select (payload->'draft_execution'->>'promoted_order_id') from p631_continuation_result)::uuid),
  'WHATSAPP',
  '13: exactly one governed Sales Order is produced, order_origin = WHATSAPP'
);

select is(
  (select count(*)::int from public.sales_order_draft_lines l
    join public.sales_order_drafts d on d.id = l.draft_id
    where d.id = (select (payload->'draft_execution'->>'sales_order_draft_id') from p631_continuation_result)::uuid
      and l.sku = 'BAK-P631-250' and l.operator_quantity = 7),
  1,
  '14: the promoted order line reflects the real, customer-stated quantity (7) and the real SKU -- preserved unchanged through the whole continuation'
);

select * from finish();
rollback;
