begin;
-- Contract + behavioural test for 20261022121000_whatsapp_materialize_non_order_ambiguity_tolerance.
-- Regression for production WA-RECOVERY-01: a stitched packet whose messages each produced a potential
-- order made whatsapp_materialize_packet_ai_case() raise "multiple potential orders ..." for non-order
-- messages (greeting, catalogue request, third-party auto-reply), looping the dispatch job forever.
-- Rollback-only. Fixtures bypass FK/trigger machinery only for the potential-order/evidence rows
-- (session_replication_role = replica), exactly the rows production holds one-per-message.
select plan(24);

-- ---------------------------------------------------------------- structure
select has_function('public', 'whatsapp_case_potential_order_id_for_correction_guard_v1', array['uuid'],
  'guard-specific resolver exists');
select function_privs_are('public', 'whatsapp_case_potential_order_id_for_correction_guard_v1', array['uuid'],
  'authenticated', array[]::text[], 'authenticated cannot execute the guard resolver');
select function_privs_are('public', 'whatsapp_case_potential_order_id_for_correction_guard_v1', array['uuid'],
  'anon', array[]::text[], 'anon cannot execute the guard resolver');
select function_privs_are('public', 'whatsapp_case_potential_order_id_for_correction_guard_v1', array['uuid'],
  'service_role', array['EXECUTE'], 'service_role may execute the guard resolver');
select ok(
  position('whatsapp_case_potential_order_id_for_correction_guard_v1' in pg_get_functiondef(
    'public.whatsapp_materialize_packet_ai_case(uuid,uuid,uuid,uuid,bigint)'::regprocedure)) > 0
  and position('whatsapp_case_potential_order_id(v_case.id)' in pg_get_functiondef(
    'public.whatsapp_materialize_packet_ai_case(uuid,uuid,uuid,uuid,bigint)'::regprocedure)) = 0,
  'TEXTUAL: materialize uses the guard resolver for the post-SO correction guard (not proof of runtime behaviour)');
select ok(
  position('multiple potential orders' in (select prosrc from pg_proc
    where oid = 'public.whatsapp_case_potential_order_id(uuid)'::regprocedure)) > 0,
  'the strict resolver is unchanged and still raises on ambiguity (clarification correlation keeps its authority)');

select has_function('public', 'whatsapp_case_potential_order_id_for_non_order_v1', array['uuid','text','numeric'],
  'intent-aware resolver exists');
select function_privs_are('public', 'whatsapp_case_potential_order_id_for_non_order_v1', array['uuid','text','numeric'],
  'authenticated', array[]::text[], 'authenticated cannot execute the intent-aware resolver');
select function_privs_are('public', 'whatsapp_case_potential_order_id_for_non_order_v1', array['uuid','text','numeric'],
  'service_role', array['EXECUTE'], 'service_role may execute the intent-aware resolver');
select ok(
  position('whatsapp_case_potential_order_id_for_non_order_v1(v_case.id, v_intent, v_confidence)' in pg_get_functiondef(
    'public.whatsapp_evaluate_and_materialize_order_autonomy(uuid,uuid,uuid,uuid,bigint)'::regprocedure)) > 0,
  'TEXTUAL: the autonomy evaluator uses the intent-aware resolver (not proof of runtime behaviour)');

-- ---------------------------------------------------------------- fixtures
insert into auth.users (id, email) values ('86610000-0000-0000-0000-000000000001', 'wa-recovery@example.test');
insert into public.users (id, email, full_name, role)
values ('86610000-0000-0000-0000-000000000001', 'wa-recovery@example.test', 'WA Recovery', 'admin');
insert into public.whatsapp_intelligence_knowledge_snapshots (
  id, schema_version, lifecycle, knowledge, content_checksum, created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  '86610000-0000-0000-0000-000000000010', 'wa-knowledge/v1', 'APPROVED', '{"terminology":{},"aliases":{}}'::jsonb,
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  '86610000-0000-0000-0000-000000000001', '86610000-0000-0000-0000-000000000001', statement_timestamp(),
  '86610000-0000-0000-0000-000000000001', statement_timestamp());
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
select public.whatsapp_activate_intelligence_knowledge_snapshot('86610000-0000-0000-0000-000000000010');

-- four contacts: 1 ambiguous/no SO (end to end), 2 ambiguous/no SO (helper), 3 ambiguous with an SO, 4 single, 5 none
insert into public.whatsapp_contacts(id, phone_number, customer_name)
select ('86610000-0000-0000-0000-0000000003' || lpad(n::text, 2, '0'))::uuid, '91966000000' || n, 'wa-recovery ' || n
from generate_series(1, 5) n;

insert into public.whatsapp_inbound_messages(id, provider_message_id, sender_phone, message_body, message_type, received_at)
select ('86610000-0000-0000-0000-0000000004' || lpad((n * 10 + k)::text, 2, '0'))::uuid,
       'wa-rec-' || n || '-' || k, '91966000000' || n,
       case k when 1 then 'Hi' else 'Please send catalog' end, 'text', statement_timestamp() + (k || ' seconds')::interval
from generate_series(1, 4) n, generate_series(1, 2) k;

insert into public.whatsapp_messages(id, contact_id, direction, message_type, content, provider, provider_message_id, status, message_timestamp, created_at)
select ('86610000-0000-0000-0000-0000000005' || lpad((n * 10 + k)::text, 2, '0'))::uuid,
       ('86610000-0000-0000-0000-0000000003' || lpad(n::text, 2, '0'))::uuid,
       'inbound', 'text', case k when 1 then 'Hi' else 'Please send catalog' end, 'click2api',
       'wa-rec-' || n || '-' || k, 'received', statement_timestamp() + (k || ' seconds')::interval, statement_timestamp()
from generate_series(1, 4) n, generate_series(1, 2) k;

select lives_ok($$
  select public.stitch_whatsapp_messages_atomic(
    ('86610000-0000-0000-0000-0000000003' || lpad(n::text, 2, '0'))::uuid,
    array[('86610000-0000-0000-0000-0000000005' || lpad((n * 10 + 1)::text, 2, '0'))::uuid,
          ('86610000-0000-0000-0000-0000000005' || lpad((n * 10 + 2)::text, 2, '0'))::uuid], 300)
  from generate_series(1, 4) n
$$, 'four two-message packets are stitched');

-- One potential order per inbound message (the production shape), plus the evidence rows linking them.
set local session_replication_role = replica;
insert into public.whatsapp_potential_orders(
  id, source_message_id, provider_message_id, sender_key, source_fingerprint, state, disposition,
  first_received_at, last_evidence_at, sales_order_id, sales_order_draft_id, domain, queue, sla_state)
select ('86610000-0000-0000-0000-0000000006' || lpad((n * 10 + k)::text, 2, '0'))::uuid,
       ('86610000-0000-0000-0000-0000000004' || lpad((n * 10 + k)::text, 2, '0'))::uuid,
       'wa-rec-' || n || '-' || k, '91966000000' || n, 'fp-wa-rec-' || n || '-' || k,
       case when n = 3 and k = 1 then 'CONVERTED' else 'FAILED_INTERPRETATION' end,
       case when n = 3 and k = 1 then 'CONVERTED' else 'ACTIVE_PENDING' end,
       statement_timestamp(), statement_timestamp(),
       case when n = 3 and k = 1 then '86610000-0000-0000-0000-000000000901'::uuid end,
       case when n = 3 and k = 1 then '86610000-0000-0000-0000-000000000902'::uuid end,
       'B2B', 'OPERATIONS', 'ON_TIME'
from generate_series(1, 4) n, generate_series(1, 2) k
where not (n = 4 and k = 2);
insert into public.whatsapp_commercial_evidence(
  potential_order_id, source_message_id, packet_id, provider_message_id, sender_key, evidence_kind,
  original_body, original_payload, provider_sent_at, deterministic_sequence)
select ('86610000-0000-0000-0000-0000000006' || lpad((n * 10 + k)::text, 2, '0'))::uuid,
       ('86610000-0000-0000-0000-0000000004' || lpad((n * 10 + k)::text, 2, '0'))::uuid,
       ('86610000-0000-0000-0000-0000000007' || lpad((n * 10 + k)::text, 2, '0'))::uuid,
       'wa-rec-' || n || '-' || k, '91966000000' || n, 'TEXT', 'x', '{}'::jsonb, statement_timestamp(), k
from generate_series(1, 4) n, generate_series(1, 2) k
where not (n = 4 and k = 2);
set local session_replication_role = origin;

-- ---------------------------------------------------------------- helper behaviour
insert into public.whatsapp_communication_cases(packet_id, case_type, status, rule_version)
select p.id, 'UNCLASSIFIED', 'OPEN', 'wa-recovery-test'
from public.whatsapp_message_packets p
where p.contact_id in ('86610000-0000-0000-0000-000000000302', '86610000-0000-0000-0000-000000000303',
                       '86610000-0000-0000-0000-000000000304');
create temporary table wa_rec_case as
select ct.phone_number, c.id as case_id
from public.whatsapp_communication_cases c
join public.whatsapp_message_packets p on p.id = c.packet_id
join public.whatsapp_contacts ct on ct.id = p.contact_id
where ct.id in ('86610000-0000-0000-0000-000000000302', '86610000-0000-0000-0000-000000000303',
                '86610000-0000-0000-0000-000000000304');

select throws_ok(
  format($f$select public.whatsapp_case_potential_order_id(%L)$f$, (select case_id from wa_rec_case where phone_number = '919660000002')),
  'P0001', 'multiple potential orders are linked to this communication case',
  'BASELINE: the strict resolver still raises for two fragment potential orders');
select is(
  public.whatsapp_case_potential_order_id_for_correction_guard_v1((select case_id from wa_rec_case where phone_number = '919660000002')),
  null::uuid,
  'ambiguous fragment potential orders with no sales order do not block (guard cannot trigger)');
select throws_ok(
  format($f$select public.whatsapp_case_potential_order_id_for_correction_guard_v1(%L)$f$, (select case_id from wa_rec_case where phone_number = '919660000003')),
  'P0001', 'multiple potential orders are linked to this communication case',
  'ambiguity where one potential order already has a sales order still fails closed');
select is(
  public.whatsapp_case_potential_order_id_for_correction_guard_v1((select case_id from wa_rec_case where phone_number = '919660000004')),
  '86610000-0000-0000-0000-000000000641'::uuid,
  'a single linked potential order is returned exactly as the strict resolver would');

-- intent-aware resolver: tolerance only for explicit non-order intents at confidence >= 0.50
select is(public.whatsapp_case_potential_order_id_for_non_order_v1(
  (select case_id from wa_rec_case where phone_number = '919660000002'), 'ENQUIRY', 0.90), null::uuid,
  'ambiguous potential orders + ENQUIRY (0.90) is tolerated');
select throws_ok(
  format($f$select public.whatsapp_case_potential_order_id_for_non_order_v1(%L, 'ORDER', 0.99)$f$, (select case_id from wa_rec_case where phone_number = '919660000002')),
  'P0001', 'multiple potential orders are linked to this communication case',
  'ambiguous potential orders + ORDER intent still fails closed (no potential order is ever picked)');
select throws_ok(
  format($f$select public.whatsapp_case_potential_order_id_for_non_order_v1(%L, 'ENQUIRY', 0.30)$f$, (select case_id from wa_rec_case where phone_number = '919660000002')),
  'P0001', 'multiple potential orders are linked to this communication case',
  'low-confidence interpretation still fails closed (it would reach potential-order capture)');
select throws_ok(
  format($f$select public.whatsapp_case_potential_order_id_for_non_order_v1(%L, 'UNCLEAR', 0.90)$f$, (select case_id from wa_rec_case where phone_number = '919660000002')),
  'P0001', 'multiple potential orders are linked to this communication case',
  'UNCLEAR intent still fails closed');
select throws_ok(
  format($f$select public.whatsapp_case_potential_order_id_for_non_order_v1(%L, 'AMENDMENT', 0.90)$f$, (select case_id from wa_rec_case where phone_number = '919660000002')),
  'P0001', 'multiple potential orders are linked to this communication case',
  'order-modification intents still fail closed into governed review');

-- ---------------------------------------------------------------- end to end (non-order, ambiguous)
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation, model_version, knowledge_snapshot_id,
  knowledge_snapshot_schema_version, knowledge_snapshot_content_checksum, interpretation_schema_version,
  prompt_policy_version, resolver_policy_version)
values ('86610000-0000-0000-0000-000000000801',
  (select packet_id from public.whatsapp_messages where provider_message_id = 'wa-rec-1-1'),
  'fp-wa-rec-1', array['wa-rec-1-1', 'wa-rec-1-2'],
  '{"confidence":0.9,"conclusion":{"intent":"ENQUIRY","summary":"catalogue request","primary_department":"SALES","recommended_action":"Send catalogue"}}'::jsonb,
  'test-model-v1', '86610000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1');

create temporary table wa_rec_materialized as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where provider_message_id = 'wa-rec-1-1'),
  '86610000-0000-0000-0000-000000000801') as payload;

select is((select payload->>'case_type' from wa_rec_materialized), 'ENQUIRY',
  'BEHAVIOUR: a non-order packet whose messages hold two potential orders now materializes as an ENQUIRY case');
select is(
  (select count(*)::int from public.orders o join public.whatsapp_potential_orders po on po.sales_order_id = o.id
   where po.sender_key = '919660000001'),
  0, 'no sales order is created');
select is(
  (select count(*)::int from public.whatsapp_potential_orders where sender_key = '919660000001' and sales_order_id is null
   and sales_order_draft_id is null), 2,
  'both historical potential orders are preserved untouched (none selected or merged)');
select is(
  (select count(*)::int from public.whatsapp_messages where contact_id = '86610000-0000-0000-0000-000000000301'), 2,
  'historical WhatsApp messages are preserved');

select * from finish();
rollback;
