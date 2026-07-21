-- P1 corrective fix: pin verifiable authority columns on self-registration INSERT.
--
-- Follow-up to 20260721150000_p1_users_companies_rls_containment.sql, found
-- during an independent security-diff review of that migration. That
-- migration's "users_self_insert_pending_only" policy correctly pinned
-- `role = 'PENDING'` on self-registration, but did not constrain any other
-- authority-bearing column. Because GRANT-level column privileges for
-- `authenticated` on public.users remain broad (unchanged by either
-- migration — see the original P1 task's validated finding #2), WITH CHECK
-- is the only enforcement layer on INSERT. Without this fix, a self-
-- registering client could submit, in the same INSERT as the PENDING row,
-- an explicit company_id and/or deleted_at value, bypassing the intended
-- "awaiting admin approval" invariant entirely.
--
-- This migration closes company_id and deleted_at specifically, because
-- both are verifiable by necessity rather than guessed defaults:
--   - company_id: a row being newly self-registered cannot yet belong to a
--     company — company_id assignment is a later, admin-driven B2B-approval
--     action (AdminClients.tsx:296 in the containment plan's call-site
--     table). It must be NULL at registration regardless of what the
--     column's literal DEFAULT clause happens to be.
--   - deleted_at: a row cannot already be soft-deleted before it exists. It
--     must be NULL at registration for the same structural reason.
--
-- NOT closed by this migration — documented gap, not silently dropped:
--   is_active, is_sales_executive, commission_rate_percentage, and
--   invite_status remain unpinned at INSERT time. Unlike company_id/
--   deleted_at, none of these has a value derivable from necessity alone —
--   each requires the column's actual stored DEFAULT, and this repository
--   contains no migration, generated-types file, or documented production
--   metadata that states those literal values (public.users predates this
--   repo's migration history and was never created here). Hardcoding a
--   plausible-looking literal without that verification would violate the
--   "do not guess defaults" requirement this fix operates under, and risks
--   silently breaking every self-registration if the guess is wrong (the
--   WITH CHECK would then reject legitimate registrations outright).
--   Closing these four requires either (a) a verified, read-only column-
--   default read against the real project —
--     SELECT column_name, column_default FROM information_schema.columns
--     WHERE table_schema = 'public' AND table_name = 'users'
--       AND column_name IN ('is_active', 'is_sales_executive',
--                            'commission_rate_percentage', 'invite_status');
--   — or (b) an authoritative statement of these defaults from someone with
--   schema access. See P1_RLS_REMEDIATION_IMPLEMENTATION_REPORT.md for the
--   current status of this residual gap. supabase/tests/
--   p1_users_companies_rls_containment.sql documents it as a named,
--   untested KNOWN GAP rather than a passing test, so it stays visible.

BEGIN;

DROP POLICY IF EXISTS "users_self_insert_pending_only" ON public.users;
CREATE POLICY "users_self_insert_pending_only"
  ON public.users
  FOR INSERT
  TO authenticated
  WITH CHECK (
    id = auth.uid()
    AND role = 'PENDING'
    AND company_id IS NULL
    AND deleted_at IS NULL
  );

COMMIT;
