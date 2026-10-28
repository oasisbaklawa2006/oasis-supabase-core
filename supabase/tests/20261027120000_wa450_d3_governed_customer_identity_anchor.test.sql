begin;
-- SQL contract for migration 20261027120000_wa450_d3_governed_customer_identity_anchor.sql
-- WA450-D3: GSTIN and other message clues must not authenticate cross-customer identity.
select plan(29);
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

insert into public.companies (id, business_name, gst_number, phone, status) values
  ('d3450000-0000-0000-0000-000000000201', 'WA450 Bound Customer Alpha', '29AAAAA0000A1Z1', '919345000201', 'active'),
  ('d3450000-0000-0000-0000-000000000202', 'WA450 Victim Customer Beta', '29BBBBB1111B2Z2', '919345000202', 'active');

insert into public.delivery_addresses (id, company_id, label, street_address, city, state, pincode, contact_phone, is_default) values
  ('d3450000-0000-0000-0000-000000000211', 'd3450000-0000-0000-0000-000000000201', 'Main', '1 Test Lane', 'Delhi', 'Delhi', '110001', '919345000201', true);

insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('d3450000-0000-0000-0000-000000000301', '919345000201', 'Bound Alpha Sender'),
  ('d3450000-0000-0000-0000-000000000302', '919345000399', 'Unbound Spoof Sender');

-- Staff relay fixture (delegated authority path)
insert into auth.users (id, email) values
  ('d3450000-0000-0000-0000-000000000401', 'wa450-staff@example.test');
insert into public.users (id, email, full_name, role, phone) values
  ('d3450000-0000-0000-0000-000000000401', 'wa450-staff@example.test', 'WA450 Staff Relay', 'SALES_EXECUTIVE', '919345000401');
insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('d3450000-0000-0000-0000-000000000401', '919345000401', 'WA450 Staff Relay');
insert into public.whatsapp_sender_commercial_authorizations (
  id, contact_id, company_id, disclosure_scope, identity_evidence, status,
  authorized_by, authorized_at, valid_until
) values (
  'd3450000-0000-0000-0000-000000000411',
  'd3450000-0000-0000-0000-000000000401',
  'd3450000-0000-0000-0000-000000000202',
  array['customer_pricing']::text[],
  '{"method":"STANDING_AUTHORITY"}'::jsonb,
  'ACTIVE',
  'd3450000-0000-0000-0000-000000000401',
  statement_timestamp(),
  statement_timestamp() + interval '30 days'
);


-- Additional fixtures: name-clue spoofing, expired delegation, multi-binding, duplicates, inactive.
insert into public.companies (id, business_name, gst_number, phone, status) values
  ('d3450000-0000-0000-0000-000000000501', 'WA450 Shared Phone Gamma', '29CCCCC2222C3Z3', '919345000501', 'active'),
  ('d3450000-0000-0000-0000-000000000502', 'WA450 Shared Phone Delta', '29DDDDD3333D4Z4', '919345000501', 'active'),
  ('d3450000-0000-0000-0000-000000000511', 'WA450 Twin Traders', '29EEEEE4444E5Z5', '919345000511', 'active'),
  ('d3450000-0000-0000-0000-000000000512', 'WA450 Twin Traders', '29FFFFF5555F6Z6', '919345000512', 'active'),
  ('d3450000-0000-0000-0000-000000000521', 'WA450 Dormant Traders', '29GGGGG6666G7Z7', '919345000521', 'inactive');

insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('d3450000-0000-0000-0000-000000000303', '919345000501', 'Bound To Two Companies'),
  ('d3450000-0000-0000-0000-000000000304', '919345000604', 'Expired Delegation Sender');

-- Delegation that already expired: must not anchor anything.
insert into public.whatsapp_sender_commercial_authorizations (
  id, contact_id, company_id, disclosure_scope, identity_evidence, status,
  authorized_by, authorized_at, valid_until
) values (
  'd3450000-0000-0000-0000-000000000412',
  'd3450000-0000-0000-0000-000000000304',
  'd3450000-0000-0000-0000-000000000202',
  array['customer_pricing']::text[],
  '{"method":"STANDING_AUTHORITY"}'::jsonb,
  'ACTIVE',
  'd3450000-0000-0000-0000-000000000401',
  statement_timestamp() - interval '40 days',
  statement_timestamp() - interval '10 days'
);

select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    jsonb_build_object('gst_number', '29AAAAA0000A1Z1')
  )),
  'RESOLVED',
  'bound sender with own GSTIN resolves via sender anchor'
);

select is(
  (select company_id::text from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    jsonb_build_object('gst_number', '29AAAAA0000A1Z1')
  )),
  'd3450000-0000-0000-0000-000000000201',
  'bound sender GSTIN maps to sender-bound company'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('gst_number', '29BBBBB1111B2Z2')
  )),
  'HELD_FOR_VERIFICATION',
  'unbound sender typing another company GSTIN is held'
);

select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('gst_number', '29BBBBB1111B2Z2')
  )),
  'AMBIGUOUS',
  'unbound GST spoof surfaces AMBIGUOUS not RESOLVED'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    jsonb_build_object('gst_number', '29BBBBB1111B2Z2')
  )),
  'HELD_FOR_VERIFICATION',
  'bound sender with foreign GSTIN is held for verification'
);

select is(
  (select (details->>'reason') from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    jsonb_build_object('gst_number', '29BBBBB1111B2Z2')
  )),
  'identity_clue_conflicts_with_sender_binding',
  'foreign GSTIN conflict exposes deterministic reason'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('multiple_gst_hints', 'true')
  )),
  'HELD_FOR_VERIFICATION',
  'multiple GST hints in one message are held'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('gst_number', '29SHORT')
  )),
  'MALFORMED_OR_SHORT_GST',
  'malformed GSTIN does not resolve'
);

select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    '{}'::jsonb
  )),
  'RESOLVED',
  'bound sender without GST still resolves on phone anchor'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000401',
    jsonb_build_object(
      'sender_is_verified_staff', 'true',
      'gst_number', '29BBBBB1111B2Z2'
    )
  )),
  'EXACT_GST_MATCH',
  'verified staff with delegated auth for target company may use GST hint'
);

select is(
  (select company_id::text from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000401',
    jsonb_build_object(
      'sender_is_verified_staff', 'true',
      'gst_number', '29BBBBB1111B2Z2'
    )
  )),
  'd3450000-0000-0000-0000-000000000202',
  'staff delegated GST hint resolves to authorized company'
);

select cmp_ok(
  (select confidence from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('gst_number', '29BBBBB1111B2Z2')
  )),
  '<',
  0.5::numeric,
  'held spoof outcomes use low confidence'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('company_name', 'WA450 Victim Customer Beta')
  )),
  'HELD_FOR_VERIFICATION',
  'unbound sender naming another company is held, not resolved by name'
);

select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('business_name', 'WA450 Victim Customer Beta')
  )),
  'AMBIGUOUS',
  'business_name alias from an unbound sender surfaces AMBIGUOUS not RESOLVED'
);

select is(
  (select company_id is null from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('name', 'WA450 Victim Customer Beta')
  )),
  true,
  'name alias from an unbound sender never yields a company id'
);

select is(
  (select (details->>'reason') from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    jsonb_build_object('company_name', 'WA450 Victim Customer Beta')
  )),
  'identity_clue_conflicts_with_sender_binding',
  'bound sender naming a different company conflicts with its binding'
);

select is(
  (select company_id::text from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    jsonb_build_object('company_name', 'WA450 Bound Customer Alpha')
  )),
  'd3450000-0000-0000-0000-000000000201',
  'bound sender naming its own company resolves to it'
);

select is(
  (select (details->>'identity_anchor') from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    jsonb_build_object('company_name', 'WA450 Bound Customer Alpha')
  )),
  'sender_binding_verified',
  'name resolution that passed the sender gate is reported as anchored'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('sender_is_verified_staff', 'true', 'gst_number', '29BBBBB1111B2Z2')
  )),
  'HELD_FOR_VERIFICATION',
  'a staff claim inside the candidate is ignored for an unverified sender (GSTIN)'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('sender_is_verified_staff', 'true', 'company_name', 'WA450 Victim Customer Beta')
  )),
  'HELD_FOR_VERIFICATION',
  'a staff claim inside the candidate is ignored for an unverified sender (name)'
);

select is(
  (select company_id::text from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000401',
    jsonb_build_object('company_name', 'WA450 Victim Customer Beta')
  )),
  'd3450000-0000-0000-0000-000000000202',
  'verified staff with delegated authority may name the authorized company'
);

select is(
  (select (details->>'reason') from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000401',
    jsonb_build_object('company_name', 'WA450 Bound Customer Alpha')
  )),
  'staff_message_clue_without_delegated_authorization',
  'verified staff naming a company without delegated authority is held'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000304',
    jsonb_build_object('gst_number', '29BBBBB1111B2Z2')
  )),
  'HELD_FOR_VERIFICATION',
  'an expired delegation is not an identity anchor'
);

select is(
  (select (details->>'reason') from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000303',
    jsonb_build_object('gst_number', '29CCCCC2222C3Z3')
  )),
  'ambiguous_sender_binding_with_message_clue',
  'a sender bound to two companies cannot be resolved by a message clue'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000303',
    '{}'::jsonb
  )),
  'MULTIPLE_PHONE_MATCHES',
  'a sender bound to two companies without a clue stays ambiguous'
);

select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('company_name', 'WA450 Twin Traders')
  )),
  'AMBIGUOUS',
  'duplicate business names are never resolved by name alone'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000302',
    jsonb_build_object('company_name', 'WA450 Dormant Traders')
  )),
  'EXPLICIT_NAME_NOT_FOUND_OR_INACTIVE',
  'an inactive company is not resolvable by name'
);

select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    jsonb_build_object('gst_number', '29AAAAA0000A1Z1', 'company_name', 'WA450 Victim Customer Beta')
  )),
  'AMBIGUOUS',
  'conflicting GSTIN and company name claims are held for verification'
);

select is(
  (select company_id from public.whatsapp_resolve_governed_customer(
    'd3450000-0000-0000-0000-000000000301',
    jsonb_build_object('gst_number', '29AAAAA0000A1Z1', 'company_name', 'WA450 Victim Customer Beta')
  )),
  null::uuid,
  'conflicting GSTIN and company name claims never expose a company id'
);

select * from finish();
rollback;
