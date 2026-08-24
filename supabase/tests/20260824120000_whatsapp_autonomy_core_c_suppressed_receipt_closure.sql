begin;
-- Suppressed non-order receipt durable outcome proofs.
select plan(6);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

insert into auth.users (id, email) values ('e1000000-0000-0000-0000-000000000001', 'suppress-human@example.test');
insert into public.users (id, email, full_name, role) values
  ('e1000000-0000-0000-0000-000000000001', 'suppress-human@example.test', 'Suppress Human', 'admin');
select public.whatsapp_core_c_ensure_system_principal();

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('e1000000-0000-0000-0000-000000000301', '919820000021', 'Unsafe Receipt Customer');
insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'e1000000-0000-0000-0000-000000000311', 'e1000000-0000-0000-0000-000000000301',
  '{"text":"complaint about delivery"}'::jsonb, 1, statement_timestamp(), statement_timestamp(), 'open'
);
insert into public.whatsapp_communication_cases(
  id, packet_id, case_type, status, source_channel, rule_version,
  accountable_team, accountable_owner_id, accountability_status,
  assigned_at, assigned_by, next_action, next_action_due_at
) values (
  'e1000000-0000-0000-0000-000000000321', 'e1000000-0000-0000-0000-000000000311',
  'COMPLAINT', 'OPEN', 'WHATSAPP', 'packet-ai-b2b-v1',
  'QUALITY', 'e1000000-0000-0000-0000-000000000001', 'ASSIGNED',
  statement_timestamp(), 'e1000000-0000-0000-0000-000000000001',
  'Operator claimed complaint', statement_timestamp() + interval '1 day'
);

create or replace function public.whatsapp_core_c_safe_non_order_receipt(
  p_case_type text,
  p_primary_department text,
  p_case_id uuid
)
returns text
language sql
immutable
set search_path = pg_catalog, public
as $$
  select 'Thank you. Your sales order SO-UNSAFE-001 is noted for follow-up.';
$$;

create temporary table suppress_first as
select public.whatsapp_apply_non_order_case_governance_v1(
  'e1000000-0000-0000-0000-000000000321',
  'e1000000-0000-0000-0000-000000000401',
  'COMPLAINT', 'QUALITY'
) as payload;

select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'e1000000-0000-0000-0000-000000000311'),
  0,
  'unsafe receipt candidate sends zero outbox rows'
);
select is(
  (select count(*)::integer from public.whatsapp_case_events
    where case_id = 'e1000000-0000-0000-0000-000000000321'
      and event_type = 'AUTONOMOUS_NON_ORDER_RECEIPT_SUPPRESSED'),
  1,
  'unsafe receipt records exactly one SUPPRESSED event'
);
select ok(
  (select (payload->>'receipt_suppressed')::boolean from suppress_first)
  and not coalesce((select (payload->>'receipt_sent')::boolean from suppress_first), false),
  'first pass returns receipt_suppressed without receipt_sent'
);

create temporary table suppress_replay as
select public.whatsapp_apply_non_order_case_governance_v1(
  'e1000000-0000-0000-0000-000000000321',
  'e1000000-0000-0000-0000-000000000401',
  'COMPLAINT', 'QUALITY'
) as payload;

select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'e1000000-0000-0000-0000-000000000311'),
  0,
  'replay creates zero additional outbox rows'
);
select is(
  (select count(*)::integer from public.whatsapp_case_events
    where case_id = 'e1000000-0000-0000-0000-000000000321'
      and event_type = 'AUTONOMOUS_NON_ORDER_RECEIPT_SUPPRESSED'),
  1,
  'replay creates zero additional SUPPRESSED events'
);
select ok(
  (select accountable_owner_id from public.whatsapp_communication_cases
    where id = 'e1000000-0000-0000-0000-000000000321')
    = 'e1000000-0000-0000-0000-000000000001'::uuid
  and (select accountability_status from public.whatsapp_communication_cases
    where id = 'e1000000-0000-0000-0000-000000000321') = 'ASSIGNED',
  'existing case owner and assignment state preserved'
);

select * from finish();
rollback;
