-- Core #407 -- contract test for migration 20261101010000_ai_studio_product_master_write_authority.sql:
-- scoped Product Master create/update + media/variant write authority; products DELETE unchanged: structure, authority matrix,
-- real authenticated/anon RLS INSERT/UPDATE/DELETE behaviour, and rollback safety.
--
-- Transactional pgTAP only; everything (synthetic identities, rows, helper
-- objects) is rolled back. Nothing here touches real accounts or data.
--
-- Triggers and FK checks are disabled for the seeded rows through
-- session_replication_role = replica (the setting survives SET ROLE). RLS is NOT
-- bypassed by that setting, so the RLS assertions below are genuine: the
-- Product Master identity/BOM/variant triggers are out of scope for #407.
--
-- Owner approved the two active legacy SUPER_ADMIN holders for Product Master
-- authoring, excluding product hard-delete; future product managers require an
-- individually governed assignment. Uppercase ADMIN, owner,
-- product_manager and catalogue_contributor are intentionally denied.
BEGIN;
SELECT plan(96);

-- ---------------------------------------------------------------------------
-- A. Structure, privileges and scope
-- ---------------------------------------------------------------------------
SELECT has_function('public', 'can_write_product_master', ARRAY[]::text[],
  'A01 scoped product authoring resolver exists');
SELECT function_returns('public', 'can_write_product_master', ARRAY[]::text[], 'boolean',
  'A02 resolver returns boolean');
SELECT ok(
  (SELECT prosecdef FROM pg_proc WHERE oid = 'public.can_write_product_master()'::regprocedure),
  'A03 resolver is SECURITY DEFINER (reads protected public.users)');
SELECT ok(
  (SELECT proconfig @> ARRAY['search_path=""'] FROM pg_proc
    WHERE oid = 'public.can_write_product_master()'::regprocedure),
  'A04 resolver pins search_path to the empty string');
SELECT is(
  (SELECT provolatile::text FROM pg_proc WHERE oid = 'public.can_write_product_master()'::regprocedure),
  's', 'A05 resolver is STABLE');
SELECT ok(has_function_privilege('authenticated', 'public.can_write_product_master()', 'EXECUTE'),
  'A06 authenticated may probe product authority');
SELECT ok(has_function_privilege('service_role', 'public.can_write_product_master()', 'EXECUTE'),
  'A07 service_role may probe product authority');
SELECT ok(NOT has_function_privilege('anon', 'public.can_write_product_master()', 'EXECUTE'),
  'A08 anon cannot execute resolver');
SELECT ok(NOT has_function_privilege('public', 'public.can_write_product_master()', 'EXECUTE'),
  'A09 PUBLIC cannot execute resolver');

SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public'
     AND (tablename, policyname, cmd) IN (
       ('products', 'Admins insert products', 'INSERT'),
       ('products', 'Admins update products', 'UPDATE'),
       ('product_media', 'Admins insert product media', 'INSERT'),
       ('product_media', 'Admins update product media', 'UPDATE'),
       ('product_media', 'Admins delete product media', 'DELETE'),
       ('product_variants', 'Admins insert product variants', 'INSERT'),
       ('product_variants', 'Admins update product variants', 'UPDATE'),
       ('product_variants', 'Admins delete product variants', 'DELETE'))
     AND roles = '{authenticated}'
     AND COALESCE(qual, '') || ' ' || COALESCE(with_check, '') LIKE '%can_write_product_master()%'
     AND COALESCE(qual, '') || ' ' || COALESCE(with_check, '') NOT LIKE '%is_admin(%'),
  8, 'A10 all eight granted Product Master mutation policies (authenticated only) use scoped authority');
SELECT ok(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN ('products', 'product_media', 'product_variants')
     AND cmd <> 'SELECT') = 9
  AND (SELECT qual FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'products'
         AND policyname = 'Admins delete products' AND cmd = 'DELETE') = 'is_admin()',
  'A11 all nine mutation policies exist but product hard-delete stays on global is_admin()');
SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public'
     AND cmd <> 'SELECT'
     AND (COALESCE(qual, '') || COALESCE(with_check, '')) LIKE '%can_write_product_master()%'),
  8, 'A12 scoped authority is referenced by exactly eight mutation policies');
SELECT is(
  (SELECT count(*)::integer FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.oid <> 'public.can_write_product_master()'::regprocedure
     AND p.prosrc LIKE '%can_write_product_master%'),
  0, 'A13 no other function is wired to the scoped authority');
SELECT is(
  (SELECT string_agg(tablename || ':' || policyname, ',' ORDER BY tablename, policyname)
     FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('products', 'product_media', 'product_variants')
      AND cmd = 'SELECT'),
  'product_media:Authenticated read product media,product_media:Public read media,'
  || 'product_variants:Authenticated read product variants,product_variants:Public read product variants,'
  || 'products:Internal staff read products',
  'A14 SELECT policy names on the three tables remain stable (visibility guarded separately)');
SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'categories'
     AND (COALESCE(qual, '') || COALESCE(with_check, '')) LIKE '%is_admin(%'),
  3, 'A15 category admin policies remain on global is_admin()');
SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'product_variants_legacy_pre_point32'
     AND (COALESCE(qual, '') || COALESCE(with_check, '')) LIKE '%is_admin(%'),
  3, 'A16 historical variant backup table stays on global is_admin()');

-- Global is_admin() must be byte-for-byte the production definition (whitespace-normalised).
SELECT is(
  (SELECT md5(regexp_replace(prosrc, '\s+', ' ', 'g')) FROM pg_proc
    WHERE oid = 'public.is_admin()'::regprocedure),
  'cf07373b925bdc1db85e6cd40fb5ce6c',
  'A17 global is_admin() source is unchanged');
SELECT ok(
  (SELECT prosecdef AND proconfig @> ARRAY['search_path=""'] AND provolatile = 's'
     FROM pg_proc WHERE oid = 'public.is_admin()'::regprocedure),
  'A18 global is_admin() attributes unchanged (SECURITY DEFINER, empty search_path, STABLE)');
SELECT ok(
  has_function_privilege('authenticated', 'public.is_admin()', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.is_admin()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.is_admin()', 'EXECUTE'),
  'A19 global is_admin() EXECUTE privileges unchanged');
SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public'
     AND (COALESCE(qual, '') || COALESCE(with_check, '')) LIKE '%is_admin(%'),
  14, 'A20 remaining policies on global is_admin() = 22 production policies minus eight migrated');

SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.product_master_authors'::regclass),
  'A21 author allowlist has RLS enabled');
SELECT is((SELECT count(*)::integer FROM pg_policies WHERE schemaname = 'public' AND tablename = 'product_master_authors'),
  0, 'A22 author allowlist exposes no client policy');
SELECT ok(NOT has_table_privilege('anon', 'public.product_master_authors', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.product_master_authors', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.product_master_authors', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.product_master_authors', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.product_master_authors', 'DELETE'),
  'A23 clients have no privilege on the author allowlist (no self-grant path)');
SELECT is((SELECT count(*)::integer FROM public.product_master_authors), 0,
  'A24 migration seeds only the two approved production identities (none exist in a clean test database)');

-- ---------------------------------------------------------------------------
-- B. Synthetic identities (no real data) and seeded rows
-- ---------------------------------------------------------------------------
SET LOCAL session_replication_role = replica;

CREATE TEMP TABLE c407_ids (label text PRIMARY KEY, sub text, role_value text, active boolean, expect_rpc boolean, expect_is_admin boolean);
INSERT INTO c407_ids VALUES
  ('admin',          '94700000-0000-0000-0000-000000000001', 'admin',                 TRUE,  TRUE,  TRUE),
  ('super_admin',    '94700000-0000-0000-0000-000000000002', 'super_admin',           TRUE,  TRUE,  TRUE),
  ('legacy_super',   '94700000-0000-0000-0000-000000000003', 'SUPER_ADMIN',           TRUE,  TRUE,  FALSE),
  ('upper_admin',    '94700000-0000-0000-0000-000000000004', 'ADMIN',                 TRUE,  FALSE, FALSE),
  ('inactive_super', '94700000-0000-0000-0000-000000000005', 'SUPER_ADMIN',           FALSE, FALSE, FALSE),
  ('contributor',    '94700000-0000-0000-0000-000000000006', 'catalogue_contributor', TRUE,  FALSE, FALSE),
  ('manager',        '94700000-0000-0000-0000-000000000007', 'product_manager',       TRUE,  FALSE, FALSE),
  ('owner',          '94700000-0000-0000-0000-000000000008', 'owner',                 TRUE,  FALSE, FALSE),
  ('inactive_admin', '94700000-0000-0000-0000-000000000009', 'admin',                 FALSE, FALSE, FALSE),
  -- Active uppercase SUPER_ADMIN holders that are NOT individually approved.
  ('future_super',   '94700000-0000-0000-0000-000000000010', 'SUPER_ADMIN',           TRUE,  FALSE, FALSE),
  ('revoked_super',  '94700000-0000-0000-0000-000000000011', 'SUPER_ADMIN',           TRUE,  FALSE, FALSE),
  ('deleted_super',  '94700000-0000-0000-0000-000000000012', 'SUPER_ADMIN',           TRUE,  FALSE, FALSE);
-- Identities without a public.users row.
INSERT INTO c407_ids VALUES
  ('unknown',  '94700000-0000-0000-0000-000000000099', NULL, NULL, FALSE, FALSE),
  ('empty_sub', '',                                    NULL, NULL, FALSE, FALSE);
GRANT ALL ON c407_ids TO PUBLIC;

INSERT INTO auth.users (id, email)
SELECT sub::uuid, 'qa-c407-' || label || '@example.invalid' FROM c407_ids WHERE role_value IS NOT NULL;
INSERT INTO public.users (id, role, email, is_active)
SELECT sub::uuid, role_value, 'qa-c407-' || label || '@example.invalid', active FROM c407_ids WHERE role_value IS NOT NULL;

-- Individual owner approvals. future_super is deliberately absent.
-- inactive_super / revoked_super / deleted_super are approved but must still be denied.
UPDATE public.users SET deleted_at = now() WHERE id = '94700000-0000-0000-0000-000000000012';
INSERT INTO public.product_master_authors (user_id, basis, approved_by, revoked_at)
SELECT sub::uuid, 'c407 test approval', 'test', CASE WHEN label = 'revoked_super' THEN now() END
FROM c407_ids WHERE label IN ('legacy_super', 'inactive_super', 'revoked_super', 'deleted_super');

CREATE TEMP TABLE c407_results (phase text, label text, tbl text, rpc boolean, outcome text);
GRANT ALL ON c407_results TO PUBLIC;

-- Seed one editable row per identity per table (names are keyed by label).
CREATE FUNCTION pg_temp.c407_seed(p_phase text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE r record;
BEGIN
  FOR r IN SELECT label FROM c407_ids LOOP
    INSERT INTO public.products (name, category, sku, hsn_code)
      VALUES ('c407-' || p_phase || '-p-' || r.label, 'c407', 'C407-' || p_phase || '-P-' || r.label, '00000000');
    INSERT INTO public.product_media (file_url) VALUES ('c407-' || p_phase || '-m-' || r.label);
    INSERT INTO public.product_variants (product_id, basis_product_id, variant_key, basis_sku, sku)
      VALUES (gen_random_uuid(), gen_random_uuid(), 'c407-' || p_phase || '-v-' || r.label, 'B', 'C407-' || p_phase || '-V-' || r.label);
  END LOOP;
END $f$;
SELECT pg_temp.c407_seed('main');

-- Runs under the CURRENT role; records INSERT / UPDATE / DELETE outcomes per table.
CREATE FUNCTION pg_temp.c407_attempt(p_phase text, p_label text, p_sub text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v_rpc boolean; v_i text; v_u integer; v_d integer; t text;
  v_nm text;
BEGIN
  PERFORM set_config('request.jwt.claim.role', current_user, true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(p_sub, ''), true);
  BEGIN
    -- Dynamic SQL: plpgsql caches simple-expression plans (incl. the EXECUTE ACL check)
    -- for the whole transaction, which would hide role changes between calls.
    EXECUTE 'SELECT public.can_write_product_master()' INTO v_rpc;
  EXCEPTION WHEN insufficient_privilege OR undefined_function THEN
    v_rpc := NULL;
  END;
  FOREACH t IN ARRAY ARRAY['products', 'product_media', 'product_variants'] LOOP
    v_i := 'ok'; v_u := 0; v_d := 0;
    v_nm := 'c407-' || p_phase || '-' || CASE t WHEN 'products' THEN 'p' WHEN 'product_media' THEN 'm' ELSE 'v' END || '-' || p_label;
    BEGIN
      IF t = 'products' THEN
        INSERT INTO public.products (name, category, sku, hsn_code)
          VALUES (v_nm || '-new', 'c407', 'C407-NEW-' || p_phase || '-' || p_label, '00000000');
        UPDATE public.products SET is_active = FALSE WHERE name = v_nm;
        GET DIAGNOSTICS v_u = ROW_COUNT;
        DELETE FROM public.products WHERE name = v_nm;
        GET DIAGNOSTICS v_d = ROW_COUNT;
      ELSIF t = 'product_media' THEN
        INSERT INTO public.product_media (file_url) VALUES (v_nm || '-new');
        UPDATE public.product_media SET file_url = file_url || '-edited' WHERE file_url = v_nm;
        GET DIAGNOSTICS v_u = ROW_COUNT;
        DELETE FROM public.product_media WHERE file_url = v_nm || '-edited' OR file_url = v_nm;
        GET DIAGNOSTICS v_d = ROW_COUNT;
      ELSE
        INSERT INTO public.product_variants (product_id, basis_product_id, variant_key, basis_sku, sku)
          VALUES (gen_random_uuid(), gen_random_uuid(), v_nm || '-new', 'B', 'C407-NEW-' || p_phase || '-' || p_label);
        UPDATE public.product_variants SET updated_at = now() WHERE variant_key = v_nm;
        GET DIAGNOSTICS v_u = ROW_COUNT;
        DELETE FROM public.product_variants WHERE variant_key = v_nm;
        GET DIAGNOSTICS v_d = ROW_COUNT;
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      v_i := 'denied';
      -- The INSERT failed, so run update/delete separately to prove they are denied too.
      BEGIN
        IF t = 'products' THEN
          UPDATE public.products SET is_active = FALSE WHERE name = v_nm; GET DIAGNOSTICS v_u = ROW_COUNT;
          DELETE FROM public.products WHERE name = v_nm; GET DIAGNOSTICS v_d = ROW_COUNT;
        ELSIF t = 'product_media' THEN
          UPDATE public.product_media SET file_url = file_url || '-edited' WHERE file_url = v_nm; GET DIAGNOSTICS v_u = ROW_COUNT;
          DELETE FROM public.product_media WHERE file_url = v_nm; GET DIAGNOSTICS v_d = ROW_COUNT;
        ELSE
          UPDATE public.product_variants SET updated_at = now() WHERE variant_key = v_nm; GET DIAGNOSTICS v_u = ROW_COUNT;
          DELETE FROM public.product_variants WHERE variant_key = v_nm; GET DIAGNOSTICS v_d = ROW_COUNT;
        END IF;
      EXCEPTION WHEN insufficient_privilege THEN
        v_u := 0; v_d := 0;
      END;
    END;
    INSERT INTO c407_results VALUES (p_phase, p_label, t, v_rpc, 'i=' || v_i || '/u=' || v_u || '/d=' || v_d);
  END LOOP;
END $f$;
GRANT EXECUTE ON FUNCTION pg_temp.c407_attempt(text, text, text) TO PUBLIC;

-- ---------------------------------------------------------------------------
-- C. Authority RPC matrix under authenticated (and anon / missing identity)
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'admin';
SELECT is(public.can_write_product_master(), TRUE, 'C01 canonical admin: authority granted');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'super_admin';
SELECT is(public.can_write_product_master(), TRUE, 'C02 canonical super_admin: authority granted');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'legacy_super';
SELECT is(public.can_write_product_master(), TRUE, 'C03 approved legacy uppercase SUPER_ADMIN: authority granted');
SELECT is(public.is_admin(), FALSE, 'C04 global is_admin() still refuses legacy SUPER_ADMIN (no global elevation)');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'upper_admin';
SELECT is(public.can_write_product_master(), FALSE, 'C05 uppercase ADMIN: denied');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'inactive_super';
SELECT is(public.can_write_product_master(), FALSE, 'C06 inactive SUPER_ADMIN: denied');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'inactive_admin';
SELECT is(public.can_write_product_master(), FALSE, 'C07 inactive canonical admin: denied');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'contributor';
SELECT is(public.can_write_product_master(), FALSE, 'C08 catalogue contributor: denied');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'manager';
SELECT is(public.can_write_product_master(), FALSE, 'C09 product_manager: denied');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'owner';
SELECT is(public.can_write_product_master(), FALSE, 'C10 owner without direct authority: denied');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'unknown';
SELECT is(public.can_write_product_master(), FALSE, 'C11 unknown/stale JWT identity: denied');
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is(public.can_write_product_master(), FALSE, 'C12 authenticated role with empty subject fails closed');
RESET request.jwt.claim.sub;
SELECT is(public.can_write_product_master(), FALSE, 'C13 authenticated role with no subject claim fails closed');

-- Full is_admin() matrix: unchanged behaviour for every identity class.
SELECT is(
  (SELECT string_agg(label || '=' || x.r::text, ',' ORDER BY label)
     FROM (SELECT label, (SELECT set_config('request.jwt.claim.sub', sub, true)) s,
                  public.is_admin() r FROM c407_ids) x),
  (SELECT string_agg(label || '=' || expect_is_admin::text, ',' ORDER BY label) FROM c407_ids),
  'C14 global is_admin() matrix unchanged for all identity classes');

-- Future / unapproved / revoked / soft-deleted SUPER_ADMIN holders are denied by the resolver.
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'future_super';
SELECT is(public.can_write_product_master(), FALSE, 'C16 future SUPER_ADMIN holder without individual approval: denied');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'revoked_super';
SELECT is(public.can_write_product_master(), FALSE, 'C17 approved-then-revoked SUPER_ADMIN: denied');
SELECT set_config('request.jwt.claim.sub', sub, true) FROM c407_ids WHERE label = 'deleted_super';
SELECT is(public.can_write_product_master(), FALSE, 'C18 approved but soft-deleted SUPER_ADMIN: denied');

-- Anonymous cannot even call the resolver.
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.can_write_product_master()$$, '42501', NULL,
  'C15 anon role cannot execute the resolver');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- D. Real RLS INSERT / UPDATE / DELETE as authenticated, anon and missing identity
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.c407_attempt('main', label, sub) FROM c407_ids ORDER BY label;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.c407_attempt('main', 'contributor', (SELECT sub FROM c407_ids WHERE label = 'admin'));
RESET ROLE;
UPDATE c407_results SET label = 'ANON_with_admin_claim' WHERE phase = 'main' AND rpc IS NULL;

-- D1: each identity/table matches the scoped write RPC; hard-delete remains
-- on global is_admin() for products, even for legacy SUPER_ADMIN.
SELECT is(r.outcome,
  CASE
    WHEN r.rpc IS FALSE THEN 'i=denied/u=0/d=0'
    WHEN r.tbl = 'products' AND r.label = 'legacy_super' THEN 'i=ok/u=1/d=0'
    ELSE 'i=ok/u=1/d=1'
  END,
  'D01 RLS agrees with authority RPC: ' || r.label || ' on ' || r.tbl)
FROM c407_results r
WHERE r.phase = 'main' AND r.rpc IS NOT NULL
ORDER BY r.tbl, r.label;

-- D2: independent hard-coded expectation (not derived from the RPC).
SELECT is(
  (SELECT bool_and(r.rpc IS NOT DISTINCT FROM i.expect_rpc) FROM c407_results r JOIN c407_ids i USING (label)
    WHERE r.phase = 'main'),
  TRUE, 'D02 RPC result matches the approved authorisation matrix for every identity');

-- D3: anon with a forged admin claim is denied at table level for all three tables.
SELECT is(
  (SELECT string_agg(tbl || ':' || outcome, ',' ORDER BY tbl) FROM c407_results WHERE label = 'ANON_with_admin_claim'),
  'product_media:i=denied/u=0/d=0,product_variants:i=denied/u=0/d=0,products:i=denied/u=0/d=0',
  'D03 anonymous role cannot insert, update or delete any Product Master row');

-- D4: denied identities lost no data; legacy SUPER_ADMIN retains the product row
-- after DELETE is denied, while allowed users can still delete their media/variant rows.
SELECT is(
  (SELECT count(*)::integer FROM public.products WHERE name LIKE 'c407-main-p-%' AND name NOT LIKE '%-new'),
  (SELECT count(*)::integer FROM c407_ids i WHERE NOT i.expect_rpc) + 1,
  'D04 products: denied identities plus the legacy SUPER_ADMIN hard-delete-denied row remain');
SELECT is(
  (SELECT count(*)::integer FROM public.product_media WHERE file_url LIKE 'c407-main-m-%' AND file_url NOT LIKE '%-new'),
  (SELECT count(*)::integer FROM c407_ids i WHERE NOT i.expect_rpc),
  'D05 product_media: exactly the denied identities'' rows remain');
SELECT is(
  (SELECT count(*)::integer FROM public.product_variants WHERE variant_key LIKE 'c407-main-v-%' AND variant_key NOT LIKE '%-new'),
  (SELECT count(*)::integer FROM c407_ids i WHERE NOT i.expect_rpc),
  'D06 product_variants: exactly the denied identities'' rows remain');

-- ---------------------------------------------------------------------------
-- E. Rollback safety: execute the documented rollback and verify prior authority
-- ---------------------------------------------------------------------------
SELECT pg_temp.c407_seed('rb');
CREATE TEMP TABLE c407_before AS
  SELECT (SELECT count(*) FROM public.products WHERE name LIKE 'c407-rb-%') p,
         (SELECT count(*) FROM public.product_media WHERE file_url LIKE 'c407-rb-%') m,
         (SELECT count(*) FROM public.product_variants WHERE variant_key LIKE 'c407-rb-%') v;

-- === documented rollback (migration header) ===
-- Core #484 later added an authenticated SELECT policy referencing the new
-- resolver; remove that *newer* dependency only within this rollback-only
-- pgTAP transaction so historical Core #407 rollback remains testable.
-- The real production policy is NOT modified by these tests (final ROLLBACK).
-- Product media visibility is independently checked by the #484 pgTAP suite.
ALTER POLICY "Authenticated read product media" ON public.product_media USING (true);
-- A later independent Core #484 private-staging migration adds Storage object
-- policies that reference this scoped writer. During the legacy #407 rollback
-- rehearsal ONLY, remove the newly added dependent policies so we can prove
-- the original rollback works. Everything is wrapped in this suite's ROLLBACK;
-- production Storage policies and buckets are not changed.
DROP POLICY IF EXISTS studio_staging_upload_staff_owned_v1 ON storage.objects;
DROP POLICY IF EXISTS studio_staging_read_owner_or_reviewer_v1 ON storage.objects;
DROP POLICY IF EXISTS studio_staging_delete_reviewer_v1 ON storage.objects;
ALTER POLICY "Admins insert products" ON public.products WITH CHECK (public.is_admin());
ALTER POLICY "Admins update products" ON public.products USING (public.is_admin()) WITH CHECK (public.is_admin());
ALTER POLICY "Admins insert product media" ON public.product_media WITH CHECK (public.is_admin());
ALTER POLICY "Admins update product media" ON public.product_media USING (public.is_admin()) WITH CHECK (public.is_admin());
ALTER POLICY "Admins delete product media" ON public.product_media USING (public.is_admin());
ALTER POLICY "Admins insert product variants" ON public.product_variants WITH CHECK (public.is_admin());
ALTER POLICY "Admins update product variants" ON public.product_variants USING (public.is_admin()) WITH CHECK (public.is_admin());
ALTER POLICY "Admins delete product variants" ON public.product_variants USING (public.is_admin());
REVOKE EXECUTE ON FUNCTION public.can_write_product_master() FROM authenticated, service_role;
DROP FUNCTION public.can_write_product_master();
DROP TABLE public.product_master_authors;
-- === end rollback ===

SELECT hasnt_function('public', 'can_write_product_master', ARRAY[]::text[], 'E01 rollback removes the scoped resolver');
SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public' AND tablename IN ('products', 'product_media', 'product_variants')
     AND cmd <> 'SELECT'
     AND (COALESCE(qual, '') || COALESCE(with_check, '')) LIKE '%is_admin(%'
     AND (COALESCE(qual, '') || COALESCE(with_check, '')) NOT LIKE '%can_write_product_master%'),
  9, 'E02 rollback restores all nine policies to global is_admin()');
SELECT is(
  (SELECT count(*)::integer FROM pg_policies
   WHERE schemaname = 'public'
     AND (COALESCE(qual, '') || COALESCE(with_check, '')) LIKE '%is_admin(%'),
  22, 'E03 rollback restores the original 22 is_admin() policies');
SELECT is(
  (SELECT p || '/' || m || '/' || v FROM (
     SELECT (SELECT count(*) FROM public.products WHERE name LIKE 'c407-rb-%') p,
            (SELECT count(*) FROM public.product_media WHERE file_url LIKE 'c407-rb-%') m,
            (SELECT count(*) FROM public.product_variants WHERE variant_key LIKE 'c407-rb-%') v) a),
  (SELECT p || '/' || m || '/' || v FROM c407_before),
  'E04 rollback loses no Product Master data');

SET LOCAL ROLE authenticated;
SELECT pg_temp.c407_attempt('rb', label, sub) FROM c407_ids WHERE label IN ('admin', 'super_admin', 'legacy_super', 'upper_admin') ORDER BY label;
RESET ROLE;
SELECT is(
  (SELECT string_agg(label || ':' || tbl || ':' || outcome, ' ' ORDER BY label, tbl) FROM c407_results
    WHERE phase = 'rb' AND label IN ('admin', 'super_admin')),
  'admin:product_media:i=ok/u=1/d=1 admin:product_variants:i=ok/u=1/d=1 admin:products:i=ok/u=1/d=1 '
  || 'super_admin:product_media:i=ok/u=1/d=1 super_admin:product_variants:i=ok/u=1/d=1 super_admin:products:i=ok/u=1/d=1',
  'E05 after rollback canonical admin/super_admin keep direct write on all three tables');
SELECT is(
  (SELECT string_agg(label || ':' || tbl || ':' || outcome, ' ' ORDER BY label, tbl) FROM c407_results
    WHERE phase = 'rb' AND label IN ('legacy_super', 'upper_admin')),
  'legacy_super:product_media:i=denied/u=0/d=0 legacy_super:product_variants:i=denied/u=0/d=0 legacy_super:products:i=denied/u=0/d=0 '
  || 'upper_admin:product_media:i=denied/u=0/d=0 upper_admin:product_variants:i=denied/u=0/d=0 upper_admin:products:i=denied/u=0/d=0',
  'E06 after rollback legacy SUPER_ADMIN is back to the pre-migration (denied) state');
SELECT is(
  (SELECT count(*)::integer FROM public.products WHERE name IN ('c407-rb-p-legacy_super', 'c407-rb-p-upper_admin')) +
  (SELECT count(*)::integer FROM public.product_media WHERE file_url IN ('c407-rb-m-legacy_super', 'c407-rb-m-upper_admin')) +
  (SELECT count(*)::integer FROM public.product_variants WHERE variant_key IN ('c407-rb-v-legacy_super', 'c407-rb-v-upper_admin')),
  6, 'E07 denied identities'' rows survive the rolled-back state');

SELECT * FROM finish();
ROLLBACK;
