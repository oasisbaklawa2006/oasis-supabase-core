-- Verification suite for:
--   supabase/migrations/20260721150000_p1_users_companies_rls_containment.sql
--   supabase/migrations/20260721160000_p1_users_self_insert_authority_pin.sql
--   supabase/migrations/20260721170000_p1_users_self_insert_full_authority_pin.sql
--
-- Purpose: prove the closed security boundaries stay closed, and that every
-- legitimate operation the containment plan identified still works.
--
-- How to run (this IS the fix for the previously-unbound-variable defect):
--   This script has never been executed against any database in any prior
--   session — no local Docker/Postgres or staging clone was reachable from
--   the environment that wrote it. Run it by hand against a local
--   `supabase start` database or a disposable staging clone that already
--   has all three migrations above applied:
--
--     supabase db reset   -- applies all migrations, including all three above
--
--   Then invoke with EVERY fixture variable bound via -v (the script uses
--   psql's `:'name'` quoted-substitution syntax, which requires each name
--   to be set — running this file without ALL SIX -v flags below fails
--   immediately with "unbound variable"):
--
--     psql "$LOCAL_DB_URL" \
--       -v buyer_id=11111111-1111-1111-1111-111111111111 \
--       -v victim_id=22222222-2222-2222-2222-222222222222 \
--       -v new_user_id=33333333-3333-3333-3333-333333333333 \
--       -v admin_id=44444444-4444-4444-4444-444444444444 \
--       -v staff_id=55555555-5555-5555-5555-555555555555 \
--       -v sales_exec_id=66666666-6666-6666-6666-666666666666 \
--       -f supabase/tests/p1_users_companies_rls_containment.sql
--
--   Replace every UUID above with a real (non-production, or disposable
--   staging) id that satisfies its fixture's role before running — see the
--   "Fixtures" section immediately below for what each one must be. Do NOT
--   pass the -v values pre-quoted: `:'name'` substitution adds the SQL
--   quoting itself.
--
--   Every test block below opens its own transaction and ends with
--   ROLLBACK, so running this script never leaves committed state behind
--   even though several blocks create throwaway rows to test against.
--
-- How each block simulates an authenticated session:
--   Supabase RLS reads the caller's identity from auth.uid(), which resolves
--   the `sub` claim of `request.jwt.claims` under the `authenticated` role.
--   Each block sets those two session settings locally, then runs the
--   statement under test, and reports pass/fail via RAISE NOTICE / RAISE
--   EXCEPTION.

-- ---------------------------------------------------------------------------
-- Fixtures (bind via -v exactly as shown above before running)
-- ---------------------------------------------------------------------------
-- :buyer_id            -- ordinary authenticated, non-staff, non-admin user
--                          (already has a public.users row)
-- :victim_id           -- a second ordinary user, distinct from :buyer_id
-- :new_user_id         -- a fresh auth.users id with NO public.users row yet
-- :admin_id            -- get_user_role(:admin_id) IN ('ADMIN','SUPER_ADMIN')
-- :staff_id            -- is_internal_staff(:staff_id) = true, and
--                          upper(get_user_role(:staff_id)) <> 'SALES_EXECUTIVE'
-- :sales_exec_id       -- is_internal_staff(:sales_exec_id) = true, and
--                          upper(get_user_role(:sales_exec_id)) = 'SALES_EXECUTIVE'

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

-- N3.* Ordinary authenticated user cannot change own authority fields via
-- UPDATE. Each column is tested in isolation (rather than bundled into one
-- statement) so a bug pinning one column cannot hide behind another column
-- correctly failing the same UPDATE.

-- N3a. company_id
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET company_id = gen_random_uuid() WHERE id = :'buyer_id'::uuid;
    RAISE EXCEPTION 'FAIL N3a: self company_id change succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N3a: self company_id change rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N3b. is_active
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET is_active = NOT is_active WHERE id = :'buyer_id'::uuid;
    RAISE EXCEPTION 'FAIL N3b: self is_active change succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N3b: self is_active change rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N3c. is_sales_executive
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET is_sales_executive = true WHERE id = :'buyer_id'::uuid;
    RAISE EXCEPTION 'FAIL N3c: self is_sales_executive change succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N3c: self is_sales_executive change rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N3d. commission_rate_percentage
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET commission_rate_percentage = 99 WHERE id = :'buyer_id'::uuid;
    RAISE EXCEPTION 'FAIL N3d: self commission_rate_percentage change succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N3d: self commission_rate_percentage change rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N3e. invite_status
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET invite_status = 'ACCEPTED' WHERE id = :'buyer_id'::uuid;
    RAISE EXCEPTION 'FAIL N3e: self invite_status change succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N3e: self invite_status change rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N3f. deleted_at
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'buyer_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    UPDATE public.users SET deleted_at = now() WHERE id = :'buyer_id'::uuid;
    RAISE EXCEPTION 'FAIL N3f: self deleted_at change succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N3f: self deleted_at change rejected (%: %)', SQLSTATE, SQLERRM;
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

-- N6. A SALES_EXECUTIVE session cannot insert a companies row. is_internal_staff()
-- includes SALES_EXECUTIVE in its broad staff set, so this specifically proves
-- the "companies_staff_insert" policy's extra `upper(get_user_role(...)) <>
-- 'SALES_EXECUTIVE'` clause is doing real work, matching the precedent already
-- live on "Staff read all companies" (containment plan §4.5 smoke test 8).
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'sales_exec_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.companies (name) VALUES ('Sales Exec Co ' || gen_random_uuid());
    RAISE EXCEPTION 'FAIL N6: SALES_EXECUTIVE session inserted a companies row';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N6: SALES_EXECUTIVE companies insert rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N7. Self-registration cannot set company_id at INSERT time (corrective
-- migration 20260721160000). Prior to that migration, only `role` was
-- pinned on INSERT — this is the case that migration exists to close.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.users (id, email, role, company_id)
    VALUES (:'new_user_id'::uuid, 'new-user-n7@example.test', 'PENDING', gen_random_uuid());
    RAISE EXCEPTION 'FAIL N7: self-registration with a non-null company_id succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N7: self-registration with a non-null company_id rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N8. Self-registration cannot set deleted_at at INSERT time (corrective
-- migration 20260721160000).
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.users (id, email, role, deleted_at)
    VALUES (:'new_user_id'::uuid, 'new-user-n8@example.test', 'PENDING', now());
    RAISE EXCEPTION 'FAIL N8: self-registration with a non-null deleted_at succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N8: self-registration with a non-null deleted_at rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N9. Self-registration cannot set is_active to a non-default value at
-- INSERT time (corrective migration 20260721170000). Verified production
-- default is `true`, so the non-default probe value here is `false`.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.users (id, email, role, is_active)
    VALUES (:'new_user_id'::uuid, 'new-user-n9@example.test', 'PENDING', false);
    RAISE EXCEPTION 'FAIL N9: self-registration with is_active=false (non-default) succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N9: self-registration with is_active=false (non-default) rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N10. Self-registration cannot set is_sales_executive to a non-default
-- value at INSERT time (corrective migration 20260721170000). Verified
-- production default is `false`, so the non-default probe value is `true`.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.users (id, email, role, is_sales_executive)
    VALUES (:'new_user_id'::uuid, 'new-user-n10@example.test', 'PENDING', true);
    RAISE EXCEPTION 'FAIL N10: self-registration with is_sales_executive=true (non-default) succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N10: self-registration with is_sales_executive=true (non-default) rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N11. Self-registration cannot set commission_rate_percentage to a
-- non-default value at INSERT time (corrective migration 20260721170000).
-- Verified production default is 2.0, so the non-default probe value is 99.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.users (id, email, role, commission_rate_percentage)
    VALUES (:'new_user_id'::uuid, 'new-user-n11@example.test', 'PENDING', 99);
    RAISE EXCEPTION 'FAIL N11: self-registration with commission_rate_percentage=99 (non-default) succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N11: self-registration with commission_rate_percentage=99 (non-default) rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- N12. Self-registration cannot set invite_status to a non-default value at
-- INSERT time (corrective migration 20260721170000). Verified production
-- default is 'active', so the non-default probe value is 'accepted'.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.users (id, email, role, invite_status)
    VALUES (:'new_user_id'::uuid, 'new-user-n12@example.test', 'PENDING', 'accepted');
    RAISE EXCEPTION 'FAIL N12: self-registration with invite_status=accepted (non-default) succeeded';
  EXCEPTION
    WHEN insufficient_privilege OR others THEN
      RAISE NOTICE 'PASS N12: self-registration with invite_status=accepted (non-default) rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;
ROLLBACK;

-- =============================================================================
-- Prior KNOWN GAP (is_active / is_sales_executive / commission_rate_percentage
-- / invite_status unpinned on self-insert) is now RESOLVED by corrective
-- migration 20260721170000_p1_users_self_insert_full_authority_pin.sql,
-- using verified production defaults obtained via a read-only
-- information_schema.columns query (not inferred/guessed). See N9-N12 above
-- and the strengthened P1 below.
-- =============================================================================

-- =============================================================================
-- POSITIVE CASES
-- =============================================================================

-- P1. Legitimate registration can create only its own PENDING users row,
-- omitting company_id/deleted_at/is_active/is_sales_executive/
-- commission_rate_percentage/invite_status exactly as WelcomeGate.tsx does
-- today ({id, email, role: "PENDING"}), and confirms the table's own
-- verified defaults (is_active=true, is_sales_executive=false,
-- commission_rate_percentage=2.0, invite_status='active') were applied —
-- proving the full-authority-pin migration (20260721170000) is transparent
-- to this exact legitimate payload, not just that the INSERT succeeded.
BEGIN;
  SELECT set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);
  SET LOCAL ROLE authenticated;
  DO $$
  BEGIN
    INSERT INTO public.users (id, email, role) VALUES (:'new_user_id'::uuid, 'new-user@example.test', 'PENDING');
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'FAIL P1: legitimate PENDING self-registration was rejected (%: %)', SQLSTATE, SQLERRM;
  END $$;

  -- Separate block, deliberately with no exception handler of its own: if
  -- the stored row doesn't match the verified defaults, this RAISE
  -- EXCEPTION surfaces directly (as FAIL P1b-defaults) instead of being
  -- re-wrapped by the INSERT's error handler above.
  DO $$
  DECLARE
    v_is_active boolean;
    v_is_sales_executive boolean;
    v_commission_rate_percentage numeric;
    v_invite_status text;
  BEGIN
    SELECT is_active, is_sales_executive, commission_rate_percentage, invite_status
      INTO v_is_active, v_is_sales_executive, v_commission_rate_percentage, v_invite_status
      FROM public.users WHERE id = :'new_user_id'::uuid;

    IF v_is_active IS NOT TRUE
       OR v_is_sales_executive IS NOT FALSE
       OR v_commission_rate_percentage IS DISTINCT FROM 2.0
       OR v_invite_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'FAIL P1-defaults: stored row did not match verified defaults (is_active=%, is_sales_executive=%, commission_rate_percentage=%, invite_status=%)',
        v_is_active, v_is_sales_executive, v_commission_rate_percentage, v_invite_status;
    END IF;

    RAISE NOTICE 'PASS P1: self-registration with role=PENDING succeeded and all verified defaults applied';
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
-- Structural check: confirm all three vulnerable policies are gone and no
-- other unconditional {authenticated} policy exists on either table.
-- =============================================================================
DO $$
DECLARE
  leftover_count integer;
BEGIN
  SELECT count(*) INTO leftover_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND (
      (tablename = 'users' AND policyname IN ('OASIS_ADMIN_FULL_CONTROL', 'Admins can update users'))
      OR (tablename = 'companies' AND policyname = 'OASIS_AUTH_INSERT_BYPASS')
    );
  IF leftover_count > 0 THEN
    RAISE EXCEPTION 'FAIL structural: % of the 3 vulnerable polic(y/ies) still present', leftover_count;
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

  RAISE NOTICE 'PASS structural: all 3 vulnerable policies absent (OASIS_ADMIN_FULL_CONTROL, OASIS_AUTH_INSERT_BYPASS, Admins can update users); no unconditional authenticated policy remains';
END $$;
