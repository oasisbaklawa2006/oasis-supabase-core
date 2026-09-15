-- Supabase production security-advisor hardening discovered during the
-- 2026-09-15 autonomous Appverse completion run.
--
-- Scope is intentionally bounded to two evidence-backed findings:
--   1. staff_provisionable_roles is a server-side provisioning allowlist but
--      was exposed to authenticated SELECT with RLS disabled.
--   2. twelve trigger/helper functions had role-mutable search_path values.
--
-- No application authority is widened. Existing service-role/server paths
-- remain available and browser/client access fails closed.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- The table is consumed by governed server authority (admin-provision-user and
-- SECURITY DEFINER staff provisioning functions). Browser clients do not need
-- direct access to the allowlist.
ALTER TABLE public.staff_provisionable_roles ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.staff_provisionable_roles FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.staff_provisionable_roles TO service_role;

DROP POLICY IF EXISTS staff_provisionable_roles_authenticated_deny
  ON public.staff_provisionable_roles;
CREATE POLICY staff_provisionable_roles_authenticated_deny
  ON public.staff_provisionable_roles
  FOR SELECT
  TO authenticated
  USING (false);

COMMENT ON TABLE public.staff_provisionable_roles IS
  'Server-side allowlist of role_key values grant_staff_role() may assign. '
  'RLS is enabled and direct client access is denied; governed server/service-role '
  'provisioning authority remains canonical.';

-- These functions use only trigger NEW/OLD values, built-ins/current_setting,
-- or pure argument evaluation. Pinning an empty search_path removes role-level
-- object-resolution influence without changing their business semantics.
ALTER FUNCTION public.prevent_b2b_dispatch_delete() SET search_path = '';
ALTER FUNCTION public.protect_b2b_dispatch_line_identity() SET search_path = '';
ALTER FUNCTION public.prevent_b2b_dispatch_append_only_update() SET search_path = '';
ALTER FUNCTION public.validate_b2b_dispatch_consignment_transition() SET search_path = '';
ALTER FUNCTION public.touch_b2b_dispatch_updated_at() SET search_path = '';
ALTER FUNCTION public.prevent_b2b_return_arrival_delete() SET search_path = '';
ALTER FUNCTION public.protect_b2b_return_receipt_evidence() SET search_path = '';
ALTER FUNCTION public.prevent_b2b_return_decision_update() SET search_path = '';
ALTER FUNCTION public.prevent_b2b_dispatch_shipping_correction_mutation() SET search_path = '';
ALTER FUNCTION public.guard_b2b_dispatch_consignment_governed_fields() SET search_path = '';
ALTER FUNCTION public.prevent_b2b_dispatch_priority_override_mutation() SET search_path = '';
ALTER FUNCTION public.is_canonical_tv_group(text) SET search_path = '';
