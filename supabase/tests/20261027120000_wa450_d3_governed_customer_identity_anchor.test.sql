begin;
-- SQL contract for migration 20261027120000_wa450_d3_governed_customer_identity_anchor.sql
-- WA450-D3: GSTIN and other message clues must not authenticate cross-customer identity.
select plan(12);
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

select * from finish();
rollback;
