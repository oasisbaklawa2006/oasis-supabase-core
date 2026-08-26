begin;

-- Regression coverage for 20260826043000_factory_production_role_alias_parity.sql.
-- The defect was a vocabulary split: Central/staff provisioning used
-- PROD_ARABIC_SWEETS and PROD_DRAGEES while Core's effective staff predicate
-- and department mapper still recognized only the older aliases. These tests
-- prove both new aliases participate in the existing staff/RLS authority,
-- preserve the legacy aliases and six-TV grouping, keep Assembly/P&A outside
-- the Production-department taxonomy, and keep dedicated tv_* device identities
-- outside internal-staff authority.

select plan(18);

select ok(
  public.is_staff_role('PROD_ARABIC_SWEETS'),
  'PROD_ARABIC_SWEETS is recognized as canonical internal Production staff'
);

select ok(
  public.is_staff_role('prod_arabic_sweets'),
  'PROD_ARABIC_SWEETS staff-role recognition is case-insensitive'
);

select ok(
  public.is_staff_role('PROD_DRAGEES'),
  'PROD_DRAGEES is recognized as canonical internal Production staff'
);

select is(
  public.role_canonical_department('PROD_ARABIC_SWEETS'),
  'ARABIC_SWEETS'::text,
  'PROD_ARABIC_SWEETS maps to the Arabic Sweets canonical department'
);

select is(
  public.role_canonical_department('PROD_ARABIC'),
  'ARABIC_SWEETS'::text,
  'legacy PROD_ARABIC alias remains valid'
);

select is(
  public.role_canonical_department('PROD_DRAGEES'),
  'CHOCOLATES_CONFECTIONERY'::text,
  'PROD_DRAGEES shares the Chocolates & Confectionery canonical department'
);

select is(
  public.role_canonical_department('HOD_DRAGEES'),
  'CHOCOLATES_CONFECTIONERY'::text,
  'existing HOD_DRAGEES mapping remains unchanged'
);

select is(
  public.role_canonical_department('PROD_DATES'),
  'FUSION_SWEETS'::text,
  'owner-corrected Dates-to-Fusion mapping remains unchanged'
);

select is(
  public.role_canonical_department('PROD_BAKERY'),
  'BAKERY'::text,
  'owner-corrected Bakery mapping remains unchanged'
);

select ok(
  public.is_staff_role('HOD_ASSEMBLY'),
  'HOD_ASSEMBLY remains an internal staff role'
);

select is(
  public.role_canonical_department('HOD_ASSEMBLY'),
  null::text,
  'HOD_ASSEMBLY intentionally has no Production department because P&A is a separate governed domain'
);

select ok(
  not public.is_staff_role('TV_DISPLAY'),
  'TV_DISPLAY remains outside internal-staff authority'
);

select ok(
  not public.is_staff_role('TV_READY'),
  'TV_READY remains outside internal-staff authority'
);

select ok(
  not public.is_staff_role('TV_ASSEMBLY'),
  'TV_ASSEMBLY remains outside internal-staff authority'
);

select is(
  public.role_canonical_department('TV_DISPLAY'),
  null::text,
  'dedicated TV device role does not acquire a Production department implicitly'
);

insert into public.users (id, role) values
  ('96000000-0000-0000-0000-000000000001', 'PROD_ARABIC_SWEETS'),
  ('96000000-0000-0000-0000-000000000002', 'PROD_DRAGEES');

select ok(
  public.is_internal_staff('96000000-0000-0000-0000-000000000001'::uuid),
  'PROD_ARABIC_SWEETS passes the existing is_internal_staff predicate used by governed Production RLS'
);

select ok(
  public.is_internal_staff('96000000-0000-0000-0000-000000000002'::uuid),
  'PROD_DRAGEES passes the existing is_internal_staff predicate used by governed Production RLS'
);

select ok(
  not public.is_staff_role('FACTORY_CERT_INVENTED_ROLE'),
  'unknown role still fails closed'
);

select * from finish();
rollback;
