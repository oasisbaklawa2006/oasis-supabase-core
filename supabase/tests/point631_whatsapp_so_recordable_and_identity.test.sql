begin;
-- MC#631 golden regressions (synthetic fixtures only; not production customer claims).
select plan(13);
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- Bengal Sweets collision fixtures (Mukesh vs Rajesh @ South Ex)
insert into public.companies (id, business_name, gst_number, phone, status) values
  ('c6311000-0000-0000-0000-000000000201', 'Bengal Sweets', '07AAAAA0000A1Z1', '919800000201', 'active'),
  ('c6311000-0000-0000-0000-000000000202', 'Bengal Sweets', '07AAAAA0000A1Z2', '919800000202', 'active');

insert into public.delivery_addresses (id, company_id, label, street_address, city, state, pincode, contact_person, is_default) values
  ('c6311000-0000-0000-0000-000000000211', 'c6311000-0000-0000-0000-000000000201', 'South Ex Branch', 'South Extension', 'Delhi', 'Delhi', '110049', 'Mukesh', true),
  ('c6311000-0000-0000-0000-000000000212', 'c6311000-0000-0000-0000-000000000202', 'South Ex Branch', 'South Extension', 'Delhi', 'Delhi', '110049', 'Rajesh', true);

insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('c6311000-0000-0000-0000-000000000301', '919111000301', 'Oasis Employee Relay');

select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'c6311000-0000-0000-0000-000000000301',
    jsonb_build_object('business_name', 'Bengal Sweets')
  )),
  'AMBIGUOUS',
  'name-only Bengal Sweets stays ambiguous when multiple verified accounts share the alias'
);

select is(
  (select company_id::text from public.whatsapp_resolve_governed_customer(
    'c6311000-0000-0000-0000-000000000301',
    jsonb_build_object('business_name', 'Bengal Sweets', 'location', 'South Ex', 'concerned_person', 'Mukesh')
  )),
  'c6311000-0000-0000-0000-000000000201',
  'Bengal Sweets + South Ex + Mukesh resolves Mukesh establishment'
);

select is(
  (select company_id::text from public.whatsapp_resolve_governed_customer(
    'c6311000-0000-0000-0000-000000000301',
    jsonb_build_object('business_name', 'Bengal Sweets', 'location', 'South Ex', 'concerned_person', 'Rajesh')
  )),
  'c6311000-0000-0000-0000-000000000202',
  'Bengal Sweets + South Ex + Rajesh resolves Rajesh establishment'
);

-- Body phone must not be confused with employee sender phone.
update public.companies set phone = '919800000999' where id = 'c6311000-0000-0000-0000-000000000201';
update public.delivery_addresses
set contact_phone = '919800000201'
where id = 'c6311000-0000-0000-0000-000000000211';

select is(
  (select company_id::text from public.whatsapp_resolve_governed_customer(
    'c6311000-0000-0000-0000-000000000301',
    jsonb_build_object('customer_phone', '+91 98000 00201')
  )),
  'c6311000-0000-0000-0000-000000000201',
  'customer phone in message body resolves customer even when sender is employee relay'
);

select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'c6311000-0000-0000-0000-000000000301',
    '{}'::jsonb
  )),
  'UNRESOLVED',
  'employee sender phone alone does not resolve commercial customer'
);

-- SO_RECORDABLE readiness dimensions without delivery address / payment terms.
select ok(
  public.whatsapp_core_b_governed_facts_so_recordable(jsonb_build_object(
    'customer', jsonb_build_object('company_id', 'c6311000-0000-0000-0000-000000000201'),
    'order_lines', jsonb_build_array(jsonb_build_object('product_id', 'c6311000-0000-0000-0000-000000000101', 'quantity', 10))
  )),
  'governed facts without delivery_address_id are SO_RECORDABLE'
);

select ok(
  not public.whatsapp_core_b_governed_facts_draft_eligible(jsonb_build_object(
    'customer', jsonb_build_object('company_id', 'c6311000-0000-0000-0000-000000000201'),
    'order_lines', '[]'::jsonb
  )),
  'empty order lines are not SO_RECORDABLE'
);

select is(
  (
    select elem->>'status'
    from jsonb_array_elements(
      public.whatsapp_build_core_b_readiness_dimensions(jsonb_build_object(
        'customer', jsonb_build_object('company_id', 'c6311000-0000-0000-0000-000000000201', 'payment_terms', null),
        'order_lines', jsonb_build_array(jsonb_build_object('quantity', 5)),
        'branch', jsonb_build_object('delivery_address_id', null)
      ))
    ) elem
    where elem->>'dimension' = 'address'
    limit 1
  ),
  'pending',
  'missing delivery address is pending (DISPATCH_READY) not draft-blocking'
);

select lives_ok(
  $$ select public.validate_sales_order_so_recordable_readiness(
    public.whatsapp_build_core_b_readiness_dimensions(jsonb_build_object(
      'customer', jsonb_build_object('company_id', 'c6311000-0000-0000-0000-000000000201'),
      'order_lines', jsonb_build_array(jsonb_build_object('quantity', 5)),
      'branch', jsonb_build_object('delivery_address_id', null)
    ))
  ) $$,
  'SO_RECORDABLE promotion validator accepts pending address/payment dimensions'
);

-- Contradictory explicit clues: body phone for company 201 vs GST for company 202.
select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'c6311000-0000-0000-0000-000000000301',
    jsonb_build_object(
      'customer_phone', '+91 98000 00201',
      'gst_number', '07AAAAA0000A1Z2'
    )
  )),
  'AMBIGUOUS',
  'body phone and GST pointing at different companies fail closed as contradictory'
);

select is(
  (select match_method from public.whatsapp_resolve_governed_customer(
    'c6311000-0000-0000-0000-000000000301',
    jsonb_build_object(
      'customer_phone', '+91 98000 00201',
      'gst_number', '07AAAAA0000A1Z2'
    )
  )),
  'CONTRADICTORY_EXPLICIT_CUSTOMER_CLUES',
  'contradictory explicit customer clues expose deterministic match_method'
);

select is(
  (select resolution_status from public.whatsapp_resolve_governed_customer(
    'c6311000-0000-0000-0000-000000000301',
    jsonb_build_object(
      'customer_phone', '+91 98000 00201',
      'gst_number', '07AAAAA0000A1Z1'
    )
  )),
  'RESOLVED',
  'aligned body phone and GST for the same company resolve'
);

select throws_ok(
  $$ select public.validate_sales_order_draft_readiness(
    public.whatsapp_build_core_b_readiness_dimensions(jsonb_build_object(
      'customer', jsonb_build_object('company_id', 'c6311000-0000-0000-0000-000000000201'),
      'order_lines', jsonb_build_array(jsonb_build_object('quantity', 5)),
      'branch', jsonb_build_object('delivery_address_id', null)
    ))
  ) $$,
  'P0001',
  null,
  'FULL readiness gate still blocks promotion when address/payment remain pending'
);

select * from finish();
rollback;
