-- AUTH-UAT-03B (#523): canonical Buyer denial after linked user deactivation.
-- Fixture changes are transaction-local and rolled back after pgTAP.
-- Existing auth01 tests cover staff/company scope and frozen-company status.
BEGIN;
SELECT plan(19);

SELECT has_function('public', 'customer_buyer_eligible_company_id', ARRAY[]::text[],
  'canonical Buyer authorization function exists');
SELECT ok((SELECT prosecdef FROM pg_proc
  WHERE oid='public.customer_buyer_eligible_company_id()'::regprocedure),
  'canonical Buyer resolver remains SECURITY DEFINER');
SELECT ok(NOT has_function_privilege('anon',
  'public.customer_buyer_eligible_company_id()', 'EXECUTE'),
  'anonymous identities cannot invoke Buyer eligibility');
SELECT ok(has_function_privilege('authenticated',
  'public.customer_buyer_eligible_company_id()', 'EXECUTE'),
  'authenticated role may invoke authoritative eligibility');
SELECT ok(
  pg_get_functiondef('public.customer_buyer_eligible_company_id()'::regprocedure)
    LIKE '%u.is_active IS FALSE%'
  AND pg_get_functiondef('public.customer_buyer_eligible_company_id()'::regprocedure)
    LIKE '%u.deleted_at IS NOT NULL%',
  'definition blocks linked inactive and soft-deleted user records'
);

DO $fixtures$
DECLARE
  v_company uuid;
  v_frozen_company uuid;
BEGIN
  -- Consistent with existing AUTH01 fixtures; never used outside rollback-only
  -- pgTAP environments. Bypass registration/credit triggers to seed test rows.
  SET LOCAL session_replication_role = replica;

  INSERT INTO public.companies (business_name, status, is_frozen)
  VALUES ('AUTH UAT03B Approval Fixture', 'active', false)
  RETURNING id INTO v_company;
  INSERT INTO public.companies (business_name, status, is_frozen)
  VALUES ('AUTH UAT03B Frozen Fixture', 'active', true)
  RETURNING id INTO v_frozen_company;

  INSERT INTO auth.users (id, email) VALUES
    ('a13b0000-0000-4000-8000-000000000001', 'uat03b-linked@example.invalid'),
    ('a13b0000-0000-4000-8000-000000000002', 'uat03b-profileonly@example.invalid'),
    ('a13b0000-0000-4000-8000-000000000003', 'uat03b-frozen@example.invalid'),
    ('a13b0000-0000-4000-8000-000000000004', 'uat03b-staff@example.invalid');

  INSERT INTO public.users (id, email, role, is_active, company_id) VALUES
    ('a13b0000-0000-4000-8000-000000000001', 'uat03b-linked@example.invalid',
     'b2b_buyer', true, v_company),
    ('a13b0000-0000-4000-8000-000000000004', 'uat03b-staff@example.invalid',
     'ADMIN', true, v_company);

  INSERT INTO public.profiles
    (id, company_id, role, is_approved, status, email) VALUES
    ('a13b0000-0000-4000-8000-000000000001',
     v_company, 'b2b_buyer', true, 'approved', 'uat03b-linked@example.invalid'),
    ('a13b0000-0000-4000-8000-000000000002',
     v_company, 'b2b_buyer', true, 'approved', 'uat03b-profileonly@example.invalid'),
    ('a13b0000-0000-4000-8000-000000000003',
     v_frozen_company, 'b2b_buyer', true, 'approved', 'uat03b-frozen@example.invalid'),
    ('a13b0000-0000-4000-8000-000000000004',
     v_company, 'ADMIN', true, 'approved', 'uat03b-staff@example.invalid');

  PERFORM set_config('uat03b.company_id', v_company::text, true);
  SET LOCAL session_replication_role = DEFAULT;
END;
$fixtures$;

SET LOCAL request.jwt.claim.role = 'authenticated';
SET LOCAL request.jwt.claim.sub = 'a13b0000-0000-4000-8000-000000000001';

SELECT is(public.customer_buyer_eligible_company_id(),
  current_setting('uat03b.company_id')::uuid,
  'active linked approved Buyer remains eligible');
SELECT is(public.auth_buyer_company_id(),
  current_setting('uat03b.company_id')::uuid,
  'legacy compatibility resolver remains eligible for active Buyer');

UPDATE public.users SET is_active = false
WHERE id = 'a13b0000-0000-4000-8000-000000000001';
SELECT is(public.customer_buyer_eligible_company_id(), NULL::uuid,
  'linked deactivated user immediately loses Buyer company eligibility');
SELECT is(public.auth_buyer_company_id(), NULL::uuid,
  'deactivated identity cannot bypass via compatibility helper');
SELECT is((SELECT count(*) FROM public.customer_company_v1()), 0::bigint,
  'deactivated Buyer cannot retrieve protected company projection');

UPDATE public.users SET is_active = true,
  deleted_at = now()
WHERE id = 'a13b0000-0000-4000-8000-000000000001';
SELECT is(public.customer_buyer_eligible_company_id(), NULL::uuid,
  'linked soft-deleted user is rejected even when is_active is true');

UPDATE public.users SET deleted_at = NULL
WHERE id = 'a13b0000-0000-4000-8000-000000000001';
SELECT is(public.customer_buyer_eligible_company_id(),
  current_setting('uat03b.company_id')::uuid,
  'restoring active nondeleted Buyer restores allowed company');

UPDATE public.profiles SET is_approved = false
WHERE id = 'a13b0000-0000-4000-8000-000000000001';
SELECT is(public.customer_buyer_eligible_company_id(), NULL::uuid,
  'profiles approval revocation independently blocks Buyer eligibility');

UPDATE public.profiles SET is_approved = true, status = 'suspended'
WHERE id = 'a13b0000-0000-4000-8000-000000000001';
SELECT is(public.customer_buyer_eligible_company_id(), NULL::uuid,
  'suspended profile independently blocks Buyer eligibility');

SET LOCAL request.jwt.claim.sub = 'a13b0000-0000-4000-8000-000000000002';
SELECT is(public.customer_buyer_eligible_company_id(),
  current_setting('uat03b.company_id')::uuid,
  'approved legacy profile-only Buyer is still eligible');
SELECT is(public.auth_buyer_company_id(),
  current_setting('uat03b.company_id')::uuid,
  'legacy profile-only Buyer still works through compatibility helper');

SET LOCAL request.jwt.claim.sub = 'a13b0000-0000-4000-8000-000000000003';
SELECT is(public.customer_buyer_eligible_company_id(), NULL::uuid,
  'frozen company blocks approved profile-only Buyer');

SET LOCAL request.jwt.claim.sub = 'a13b0000-0000-4000-8000-000000000004';
SELECT is(public.customer_buyer_eligible_company_id(), NULL::uuid,
  'internal staff profile cannot gain Buyer access');

SET LOCAL request.jwt.claim.sub = 'a13b0000-0000-4000-8000-000000000005';
SELECT is(public.customer_buyer_eligible_company_id(), NULL::uuid,
  'unrelated authenticated identity cannot gain Buyer access');

SELECT * FROM finish();
ROLLBACK;
