-- Contract for migration 20260830120001_wa_stage1b_unclear_clarification_autonomy.sql
begin;

select plan(2);

select isnt_empty(
  $$select 1
    from pg_proc
   where oid = 'public.whatsapp_evaluate_and_materialize_order_autonomy(uuid,uuid,uuid,uuid,bigint)'::regprocedure
     and pg_get_functiondef(oid) like '%unclear_intent_requires_clarification%'$$,
  'autonomy evaluator maps advisory unclear clarification to CLARIFICATION_REQUIRED'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a1000000-0000-0000-0000-000000000980', '919800000098', 'Stage1B Unclear Clarify Contact');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'a1000000-0000-0000-0000-000000000981', 'prov-msg-unclear-clarify', '919800000098',
  'Quantity: 12 boxes', 'image', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'a1000000-0000-0000-0000-000000000982', 'a1000000-0000-0000-0000-000000000980',
  'inbound', 'image', 'Quantity: 12 boxes', 'click2api',
  'prov-msg-unclear-clarify', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000980',
  array['a1000000-0000-0000-0000-000000000982'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'a1000000-0000-0000-0000-000000000983',
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000982'),
  'fp-unclear-clarify-test',
  array['prov-msg-unclear-clarify'],
  '{
    "confidence": 0.85,
    "conclusion": {
      "intent": "UNCLEAR",
      "summary": "Quantity only image without product",
      "order_lines": [],
      "explicit_facts": [{"kind": "quantity", "value": "12 boxes"}],
      "reply_clearance": "CLARIFICATION_REQUIRED"
    }
  }'::jsonb,
  'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  '1111111111111111111111111111111111111111111111111111111111111111',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table unclear_clarify_res as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000982'),
  'a1000000-0000-0000-0000-000000000983'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from unclear_clarify_res),
  'CLARIFICATION_REQUIRED',
  'UNCLEAR advisory interpretation with clarification clearance requires customer clarification'
);

select * from finish();
rollback;
