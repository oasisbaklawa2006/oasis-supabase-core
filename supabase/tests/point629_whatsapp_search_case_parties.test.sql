begin;
-- Mission Control #629 — whatsapp_search_case_parties() contract
-- (20261011121000_whatsapp_case_party_search.sql).
--
-- Backs the Central ORIGINAL_COMMUNICATOR search-and-select picker that
-- replaced a hand-typed canonical party UUID (companion Central PR). Reuses
-- existing companies/org_contacts/users tables; mirrors the existing
-- whatsapp_search_b2b_companies() permission gate and shape exactly.

select plan(7);

-- Fixtures: distinct id prefix.
insert into public.companies (id, business_name, gst_number, phone, payment_terms, status, is_frozen) values
  ('c6320000-0000-0000-0000-000000000201', 'Point632 Party Search Co', '27PQRSX5678G1Z5', '919800000221', 'credit', 'active', false);

insert into public.org_contacts (id, company_id, name, phone) values
  ('c6320000-0000-0000-0000-000000000211', 'c6320000-0000-0000-0000-000000000201', 'Point632 Contact Person', '919800000231');

insert into auth.users (id, email) values
  ('c6320000-0000-0000-0000-000000000901', 'p632-reader@example.test'),
  ('c6320000-0000-0000-0000-000000000902', 'p632-no-permission@example.test');
insert into public.users (id, email, full_name, mobile_number, role, is_active) values
  ('c6320000-0000-0000-0000-000000000901', 'p632-reader@example.test', 'Point632 Employee Reader', '919800000241', 'support_executive', true),
  ('c6320000-0000-0000-0000-000000000902', 'p632-no-permission@example.test', 'Point632 No Permission', '919800000242', 'support_executive', true);
insert into public.user_role_map(user_id, role_id)
select 'c6320000-0000-0000-0000-000000000901', id from public.roles where role_key = 'support_executive'
on conflict (user_id, role_id) do nothing;

-- A real, permission-gated operator (wa.intake.read via the mapped role).
select set_config('request.jwt.claims', json_build_object('sub','c6320000-0000-0000-0000-000000000901','role','authenticated','aal','aal1')::text, true);
set local role authenticated;

select is(
  (select count(*)::int from public.whatsapp_search_case_parties('COMPANY', 'Point632 Party Search', 20)),
  1,
  '1: company search finds the real company by name'
);

select is(
  (select company_name from public.whatsapp_search_case_parties('CUSTOMER', '919800000221', 20) limit 1),
  'Point632 Party Search Co',
  '2: CUSTOMER party type searches the same companies table as COMPANY (by phone)'
);

select is(
  (select company_name from public.whatsapp_search_case_parties('CONTACT', 'Point632 Contact', 20) limit 1),
  'Point632 Party Search Co',
  '3: contact search finds the real org_contacts row and resolves its company name'
);

select is(
  (select display_label from public.whatsapp_search_case_parties('EMPLOYEE', 'Point632 Employee Reader', 20) limit 1),
  'Point632 Employee Reader',
  '4: employee search finds the real active user by name'
);

select throws_ok(
  $$select * from public.whatsapp_search_case_parties('UNKNOWN', 'anything', 20)$$,
  'party search requires COMPANY, CUSTOMER, CONTACT or EMPLOYEE',
  '5: an unsupported party type is rejected -- UNKNOWN is never searchable'
);

select throws_ok(
  $$select * from public.whatsapp_search_case_parties('COMPANY', 'x', 20)$$,
  'party search requires 2-100 characters',
  '6: a too-short query is rejected'
);

reset role;

-- An authenticated user with NO wa.intake.read permission is denied, exactly
-- like the existing whatsapp_search_b2b_companies() gate.
select set_config('request.jwt.claims', json_build_object('sub','c6320000-0000-0000-0000-000000000902','role','authenticated','aal','aal1')::text, true);
set local role authenticated;

select throws_ok(
  $$select * from public.whatsapp_search_case_parties('COMPANY', 'Point632', 20)$$,
  'WhatsApp inbox read permission required',
  '7: an operator without wa.intake.read is denied -- the same gate as whatsapp_search_b2b_companies'
);

reset role;

select * from finish();
rollback;
