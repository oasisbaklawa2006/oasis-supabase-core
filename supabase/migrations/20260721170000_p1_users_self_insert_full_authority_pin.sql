-- P1 corrective fix: pin the remaining authority columns on self-registration
-- INSERT, using verified production column defaults.
--
-- Follow-up to:
--   20260721150000_p1_users_companies_rls_containment.sql (drops the three
--     unconditionally-permissive policies; pins role='PENDING' on INSERT)
--   20260721160000_p1_users_self_insert_authority_pin.sql (pins company_id
--     and deleted_at to NULL on INSERT, using necessity-based reasoning —
--     that migration's header explicitly left is_active, is_sales_executive,
--     commission_rate_percentage, and invite_status open, because their
--     literal DEFAULT values were not stated anywhere in this repository or
--     in any available production-facing document, and this repo's "do not
--     guess defaults" constraint ruled out hardcoding a plausible value.
--
-- That gap is closed by this migration. The defaults below were obtained via
-- a read-only `information_schema.columns` query run against the actual
-- project (tcxvcatsqqertcnycuop) by someone with schema access — NOT
-- inferred, NOT guessed:
--
--   column                       | default      | nullable | type
--   ------------------------------+--------------+----------+---------
--   is_active                    | true         | YES      | boolean
--   is_sales_executive           | false        | NO       | boolean
--   commission_rate_percentage   | 2.0          | YES      | numeric
--   invite_status                | 'active'     | YES      | text
--
-- Each is pinned to that exact verified default via IS NOT DISTINCT FROM,
-- the same idiom already used by "users_self_update_no_authority_change"
-- (20260721150000) for the analogous UPDATE-side comparison. Because a
-- self-registering client that omits these columns already receives exactly
-- these values from the table's own DEFAULT clauses, this pin is
-- transparent to the existing WelcomeGate.tsx registration payload
-- ({id, email, role: "PENDING"}, which never sets any of these four
-- columns) — the client's own resulting row already equals what is
-- required here, so legitimate registration is unaffected. What this
-- closes is a client explicitly overriding one of these columns to a
-- non-default value (e.g. is_active = true is already the default, so no
-- change there — but is_sales_executive = true, commission_rate_percentage
-- set to any value other than 2.0, or invite_status set to any value
-- other than 'active' are now rejected).
--
-- Combined with the two prior migrations, self-registration now requires
-- ALL of: id = auth.uid(), role = 'PENDING', company_id IS NULL,
-- deleted_at IS NULL, is_active IS NOT DISTINCT FROM true,
-- is_sales_executive IS NOT DISTINCT FROM false,
-- commission_rate_percentage IS NOT DISTINCT FROM 2.0, and
-- invite_status IS NOT DISTINCT FROM 'active'. Every identity/authority
-- field named in the original P1 task is now pinned on self-registration,
-- not just role.

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
    AND is_active IS NOT DISTINCT FROM true
    AND is_sales_executive IS NOT DISTINCT FROM false
    AND commission_rate_percentage IS NOT DISTINCT FROM 2.0
    AND invite_status IS NOT DISTINCT FROM 'active'
  );

COMMIT;
