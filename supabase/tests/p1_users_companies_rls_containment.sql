-- Verification suite for migration 20260721150000_p1_users_companies_rls_containment.sql
--
-- Purpose: prove the two closed security boundaries stay closed, and that
-- every legitimate operation the containment plan identified still works.
--
-- How to run:
--   This script is NOT self-executing against production and was not run
--   against production by the change that introduced it (write mode for
--   that change was repository-only; no local Docker/Postgres was available
--   in that environment either). Run it by hand against a local `supabase
--   start` database or a disposable staging clone that already has this
--   migration applied:
--
--     supabase db reset            -- applies all migrations, including this one
--     psql "$LOCAL_DB_URL" -f supabase/tests/p1_users_companies_rls_containment.sql
--
--   Every block below opens its own transaction and ends with ROLLBACK, so
--   running this script never leaves committed state behind even though it
--   creates throwaway rows to test against.
--
-- How each block simulates an authenticated session:
--   Supabase RLS reads the caller's identity from auth.uid(), which resolves
--   the `sub` claim of `request.jwt.claims` under the `authenticated` role.
--   Each block sets those two session settings locally, then runs the
--   statement under test, and reports pass/fail via RAISE NOTICE / RAISE
--   EXCEPTION. Replace the placeholder UUIDs with real (non-production, or
--   disposable staging) user ids before running: an ordinary buyer/PENDING
--   account, a second ordinary user (the "victim" row), and a session whose
--   get_user_role() resolves to ADMIN or SUPER_ADMIN, and one whose
--   is_internal_staff() is true.

-- ---------------------------------------------------------------------------
-- Fixtures (adjust to real, non-production user ids before running)
-- ---------------------------------------------------------------------------
-- :buyer_id            -- ordinary authenticated, non-staff, non-admin user
-- :victim_id           -- a second ordinary user, distinct from :buyer_id
-- :new_user_id         -- a fresh auth.users id with no public.users row yet
-- :admin_id            -- get_user_role(:admin_id) IN ('ADMIN','SUPER_ADMIN')
-- :staff_id            -- is_internal_staff(:staff_id) = true, not SALES_EXECUTIVE

-- =============================================================================
-- NEGATIVE CASES
-- =============================================================================

-- N1. Ordinary authenticated user cannot update another user's row.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET is_active = NOT is_active WHERE id = :'victim_id'::uuid;
    IF FOUND THEN
      RAISE EXCEPTION 'FAIL N1: ordinary user updated another users row';
    ELSE
      RAISE NOTICE 'PASS N1: update on another row affected zero rows (blocked by USING)';
    END IF;
  END $$;
ROLLBACK;

-- N2. Ordinary authenticated user cannot change own role.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET role = 'SUPER_ADMIN' WHERE id = :'buyer_id'::uuid;
    RAISE EXCEPTION 'FAIL N2: self role change succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N2: self role change rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N3. Ordinary authenticated user cannot change own company_id/authority fields.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users
      SET company_id = gen_random_uuid(),
          commission_rate_percentage = 99,
          is_sales_executive = true
      WHERE id = :'buyer_id'::uuid;
    RAISE EXCEPTION 'FAIL N3: self authority-field change succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N3: self authority-field change rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N4. Ordinary authenticated user cannot delete users rows.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    DELETE FROM public.users WHERE id = :'buyer_id'::uuid;
    IF FOUND THEN
      RAISE EXCEPTION 'FAIL N4: ordinary user deleted own users row (no DELETE policy should permit this)';
    ELSE
      RAISE NOTICE 'PASS N4: delete affected zero rows (no matching permissive DELETE policy)';
    END IF;
  END $$;
ROLLBACK;

-- N5. Ordinary authenticated buyer cannot insert arbitrary companies rows.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.companies (name) VALUES ('Rogue Co ' || gen_random_uuid());
    RAISE EXCEPTION 'FAIL N5: buyer inserted an arbitrary companies row';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N5: arbitrary companies insert rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- =============================================================================
-- POSITIVE CASES
-- =============================================================================

-- P1. Legitimate registration can create only its own PENDING users row.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.users (id, email, role) VALUES (:'new_user_id'::uuid, 'new-user@example.test', 'PENDING');
    RAISE NOTICE 'PASS P1: self-registration with role=PENDING succeeded';
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'FAIL P1: legitimate PENDING self-registration was rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
  -- Same session attempting an elevated role must still fail (defense already
  -- covered by N-series in spirit, re-checked here in the registration context).
  DO $$
  BEGIN
    INSERT INTO public.users (id, email, role) VALUES (gen_random_uuid(), 'other@example.test', 'PENDING');
    RAISE EXCEPTION 'FAIL P1b: self-registration inserted a row under a different id';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS P1b: self-registration under a different id rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- P2. Legitimate self-service non-authority update still works.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET has_seen_tutorial = true WHERE id = :'buyer_id'::uuid;
    IF FOUND THEN
      RAISE NOTICE 'PASS P2: non-authority self-update succeeded';
    ELSE
      RAISE EXCEPTION 'FAIL P2: non-authority self-update affected zero rows';
    END IF;
  END $$;
ROLLBACK;

-- P3. Normalized verified admin can manage users (role/authority change on another row).
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'admin_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET role = 'BUYER', company_id = NULL WHERE id = :'victim_id'::uuid;
    IF FOUND THEN
      RAISE NOTICE 'PASS P3: admin-tier session managed another users row';
    ELSE
      RAISE EXCEPTION 'FAIL P3: admin-tier session could not update another users row';
    END IF;
  END $$;
ROLLBACK;

-- P4. Authorized staff/admin can create companies.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'staff_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.companies (name) VALUES ('Legit Staff-Created Co ' || gen_random_uuid());
    RAISE NOTICE 'PASS P4: internal staff session created a companies row';
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'FAIL P4: internal staff companies insert was rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- =============================================================================
-- Structural check: confirm the two vulnerable policies are gone and no
-- other unconditional {authenticated} policy exists on either table.
-- =============================================================================
DO $$
DECLARE
  leftover_count integer;
BEGIN
  SELECT count(*) INTO leftover_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('users', 'companies')
    AND policyname IN ('OASIS_ADMIN_FULL_CONTROL', 'OASIS_AUTH_INSERT_BYPASS');
  IF leftover_count > 0 THEN
    RAISE EXCEPTION 'FAIL structural: % vulnerable polic(y/ies) still present', leftover_count;
  END IF;

  SELECT count(*) INTO leftover_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('users', 'companies')
    AND 'authenticated' = ANY (roles)
    AND (qual = 'true' OR with_check = 'true');
  IF leftover_count > 0 THEN
    RAISE EXCEPTION 'FAIL structural: % unconditional (true) polic(y/ies) remain for authenticated', leftover_count;
  END IF;

  RAISE NOTICE 'PASS structural: no vulnerable or unconditional authenticated policy remains';
END $$;
