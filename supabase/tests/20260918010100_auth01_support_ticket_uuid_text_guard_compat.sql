-- Contract and behavioral coverage for migration:
-- 20260918010100_auth01_support_ticket_uuid_text_guard_compat.sql

begin;
select plan(6);

select ok(
  (select prosecdef from pg_proc where oid = 'public.customer_support_tickets_v1()'::regprocedure)
  and (select proconfig @> array['search_path=pg_catalog, public']
       from pg_proc where oid = 'public.customer_support_tickets_v1()'::regprocedure),
  'support projection remains SECURITY DEFINER with minimal fixed search_path'
);

select ok(
  pg_get_functiondef('public.customer_support_tickets_v1()'::regprocedure)
    like '%CASE%st.order_id%~*%[0-9a-f]{4}%THEN st.order_id::uuid%',
  'support projection keeps the UUID cast behind a CASE shape guard'
);

insert into auth.users (id, email)
values ('a1800100-0000-0000-0000-000000000001', 'auth01-uuid-compat-buyer@example.invalid');

set local session_replication_role = replica;

insert into public.companies (id, business_name, status, is_frozen)
values
(
  'a1800100-0000-0000-0000-000000000010',
  'AUTH01 UUID Compatibility Co',
  'active',
  false
),
(
  'a1800100-0000-0000-0000-000000000011',
  'AUTH01 Other Company',
  'active',
  false
);

insert into public.users (id, email, role, is_active, company_id)
values (
  'a1800100-0000-0000-0000-000000000001',
  'auth01-uuid-compat-buyer@example.invalid',
  'customer_user',
  true,
  'a1800100-0000-0000-0000-000000000010'
);

insert into public.profiles (id, company_id, role, is_approved, status, email)
values (
  'a1800100-0000-0000-0000-000000000001',
  'a1800100-0000-0000-0000-000000000010',
  'b2b_buyer',
  true,
  'approved',
  'auth01-uuid-compat-buyer@example.invalid'
);

insert into public.orders (
  id, company_id, order_number, order_origin, tracking_token,
  sales_order_value, advance_required, status
) values
(
  '00000000-0000-0000-0000-000000000001',
  'a1800100-0000-0000-0000-000000000010',
  'AUTH01-NONRFC-UUID-001',
  'MANUAL',
  'auth01-nonrfc-uuid-001',
  1000,
  300,
  'draft'
),
(
  '00000000-0000-0000-0000-000000000002',
  'a1800100-0000-0000-0000-000000000011',
  'AUTH01-OTHER-COMPANY-ORDER',
  'MANUAL',
  'auth01-other-company-order',
  2000,
  600,
  'draft'
);

insert into public.support_tickets (
  id, order_id, company_id, created_by, user_id,
  issue_type, description, status
) values
(
  'a1800100-0000-0000-0000-000000000020',
  '00000000-0000-0000-0000-000000000001',
  'a1800100-0000-0000-0000-000000000010',
  'a1800100-0000-0000-0000-000000000001',
  'a1800100-0000-0000-0000-000000000001',
  'delivery_issue',
  'Valid PostgreSQL UUID compatibility projection fixture.',
  'open'
),
(
  'a1800100-0000-0000-0000-000000000021',
  'not-a-uuid',
  'a1800100-0000-0000-0000-000000000010',
  'a1800100-0000-0000-0000-000000000001',
  'a1800100-0000-0000-0000-000000000001',
  'delivery_issue',
  'Malformed legacy order identifier must remain harmless.',
  'open'
),
(
  'a1800100-0000-0000-0000-000000000022',
  '00000000-0000-0000-0000-000000000002',
  'a1800100-0000-0000-0000-000000000010',
  'a1800100-0000-0000-0000-000000000001',
  'a1800100-0000-0000-0000-000000000001',
  'delivery_issue',
  'Legacy ticket points at another company order and must not disclose it.',
  'open'
);

set local session_replication_role = default;
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a1800100-0000-0000-0000-000000000001';

select is(
  public.customer_buyer_eligible_company_id(),
  'a1800100-0000-0000-0000-000000000010'::uuid,
  'fixture resolves through canonical Buyer eligibility authority'
);

select is(
  (
    select order_number
    from public.customer_support_tickets_v1()
    where ticket_id = 'a1800100-0000-0000-0000-000000000020'::uuid
  ),
  'AUTH01-NONRFC-UUID-001'::text,
  'valid PostgreSQL UUID text with zero version/variant bits resolves matching order_number'
);

select is(
  (
    select order_number
    from public.customer_support_tickets_v1()
    where ticket_id = 'a1800100-0000-0000-0000-000000000021'::uuid
  ),
  null::text,
  'malformed legacy order_id remains safely uncast and does not resolve an order'
);

select is(
  (
    select order_number
    from public.customer_support_tickets_v1()
    where ticket_id = 'a1800100-0000-0000-0000-000000000022'::uuid
  ),
  null::text,
  'visible ticket cannot expose order metadata belonging to another company'
);

select * from finish();
rollback;
