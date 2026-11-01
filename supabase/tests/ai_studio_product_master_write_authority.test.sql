-- Core #407 — positive/negative auth and RLS contract; transactional pgTAP only.
-- Non-production test; intentionally leaves the global is_admin() function unchanged.
BEGIN;
SELECT plan(20);

SELECT has_function('public', 'can_write_product_master', ARRAY[]::text[],
  'scoped product authoring resolver exists');
SELECT ok(
  (SELECT prosecdef FROM pg_proc WHERE oid = 'public.can_write_product_master()'::regprocedure),
  'scoped resolver uses SECURITY DEFINER to check protected public.users');
SELECT ok(
  (SELECT proconfig @> ARRAY['search_path='] FROM pg_proc
    WHERE oid = 'public.can_write_product_master()'::regprocedure),
  'scoped resolver fixes the search_path to the empty string');
SELECT ok(has_function_privilege('authenticated', 'public.can_write_product_master()', 'EXECUTE'),
  'authenticated users may probe product authority');
SELECT ok(NOT has_function_privilege('anon', 'public.can_write_product_master()', 'EXECUTE'),
  'anonymous users cannot invoke product authoring resolver');
SELECT ok(NOT has_function_privilege('public', 'public.can_write_product_master()', 'EXECUTE'),
  'PUBLIC cannot invoke product authoring resolver');

-- Every mutation policy on the three canonical Product Master tables must use
-- exactly the same authority as the frontend. Do not alter legacy variant backups.
SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN ('products', 'product_media', 'product_variants')
     AND policyname IN (
       'Admins insert products', 'Admins update products', 'Admins delete products',
       'Admins insert product media', 'Admins update product media', 'Admins delete product media',
       'Admins insert product variants', 'Admins update product variants',
       'Admins delete product variants'
     )
     AND COALESCE(qual, '') || ' ' || COALESCE(with_check, '')
         LIKE '%can_write_product_master()%'),
  9, 'all nine canonical Product Master mutation policies call scoped authority');

SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN ('products', 'product_media', 'product_variants')
     AND (COALESCE(qual, '') LIKE '%is_admin(%'
          OR COALESCE(with_check, '') LIKE '%is_admin(%')),
  0, 'no canonical Product Master mutation policy retains a divergent admin gate');

SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'categories'
     AND (COALESCE(qual, '') LIKE '%is_admin(%'
          OR COALESCE(with_check, '') LIKE '%is_admin(%')),
  3, 'category admin policies remain on the original global is_admin authority');

SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'product_variants_legacy_pre_point32'
     AND (COALESCE(qual, '') LIKE '%is_admin(%'
          OR COALESCE(with_check, '') LIKE '%is_admin(%')),
  3, 'historical variant backup remains outside authoring scope');

-- The seven synthetic identities contain no real account data.
SET LOCAL session_replication_role = replica;
INSERT INTO auth.users (id, email) VALUES
 ('94700000-0000-0000-0000-000000000001', 'qa-c407-canonical-admin@example.invalid'),
 ('94700000-0000-0000-0000-000000000002', 'qa-c407-canonical-super@example.invalid'),
 ('94700000-0000-0000-0000-000000000003', 'qa-c407-legacy-super@example.invalid'),
 ('94700000-0000-0000-0000-000000000004', 'qa-c407-uppercase-admin@example.invalid'),
 ('94700000-0000-0000-0000-000000000005', 'qa-c407-inactive-super@example.invalid'),
 ('94700000-0000-0000-0000-000000000006', 'qa-c407-contributor@example.invalid'),
 ('94700000-0000-0000-0000-000000000007', 'qa-c407-manager@example.invalid');
INSERT INTO public.users (id, role, email, is_active) VALUES
 ('94700000-0000-0000-0000-000000000001', 'admin', 'qa-c407-canonical-admin@example.invalid', TRUE),
 ('94700000-0000-0000-0000-000000000002', 'super_admin', 'qa-c407-canonical-super@example.invalid', TRUE),
 ('94700000-0000-0000-0000-000000000003', 'SUPER_ADMIN', 'qa-c407-legacy-super@example.invalid', TRUE),
 ('94700000-0000-0000-0000-000000000004', 'ADMIN', 'qa-c407-uppercase-admin@example.invalid', TRUE),
 ('94700000-0000-0000-0000-000000000005', 'SUPER_ADMIN', 'qa-c407-inactive-super@example.invalid', FALSE),
 ('94700000-0000-0000-0000-000000000006', 'catalogue_contributor', 'qa-c407-contributor@example.invalid', TRUE),
 ('94700000-0000-0000-0000-000000000007', 'product_manager', 'qa-c407-manager@example.invalid', TRUE);
SET LOCAL session_replication_role = origin;

SET LOCAL request.jwt.claim.role = 'authenticated';
SET LOCAL request.jwt.claim.sub = '94700000-0000-0000-0000-000000000001';
SELECT is(public.can_write_product_master(), TRUE, 'canonical admin keeps existing direct-write authority');
SET LOCAL request.jwt.claim.sub = '94700000-0000-0000-0000-000000000002';
SELECT is(public.can_write_product_master(), TRUE, 'canonical super_admin keeps direct-write authority');
SET LOCAL request.jwt.claim.sub = '94700000-0000-0000-0000-000000000003';
SELECT is(public.can_write_product_master(), TRUE, 'legacy uppercase SUPER_ADMIN gains product-only authority');
SELECT is(public.is_admin(), FALSE, 'global is_admin does not elevate uppercase SUPER_ADMIN');

SET LOCAL request.jwt.claim.sub = '94700000-0000-0000-0000-000000000004';
SELECT is(public.can_write_product_master(), FALSE, 'uppercase ADMIN remains denied');
SET LOCAL request.jwt.claim.sub = '94700000-0000-0000-0000-000000000005';
SELECT is(public.can_write_product_master(), FALSE, 'inactive legacy super_admin remains denied');
SET LOCAL request.jwt.claim.sub = '94700000-0000-0000-0000-000000000006';
SELECT is(public.can_write_product_master(), FALSE, 'catalogue contributor cannot directly mutate master rows');
SET LOCAL request.jwt.claim.sub = '94700000-0000-0000-0000-000000000007';
SELECT is(public.can_write_product_master(), FALSE, 'product_manager cannot bypass Core RLS');

SET LOCAL request.jwt.claim.sub = '94700000-0000-0000-0000-000000000099';
SELECT is(public.can_write_product_master(), FALSE, 'unknown/stale JWT identity denied');

RESET request.jwt.claim.sub;
SELECT is(public.can_write_product_master(), FALSE, 'unauthenticated identity denied even under server test role');

SELECT * FROM finish();
ROLLBACK;
