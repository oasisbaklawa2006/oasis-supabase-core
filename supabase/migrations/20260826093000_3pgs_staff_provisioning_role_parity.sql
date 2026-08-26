-- Factory Operations certification found that Central's canonical 3PGS role
-- STORE_3RD_PARTY is accepted by the existing 3PGS inventory authority
-- predicates, but is absent from the governed staff provisioning allowlist.
-- That makes the role impossible to create through grant_staff_role(), even
-- though Central routes and Core 3PGS RPCs already recognize it.
--
-- Narrow parity fix only: no new business authority, no RLS broadening and no
-- production data mutation. It makes the existing STORE_3RD_PARTY identity
-- governably provisionable through the same server authority as other staff.

INSERT INTO public.staff_provisionable_roles (
  role_key,
  description,
  requires_step_up,
  is_active
)
VALUES (
  'store_3rd_party',
  '3PGS / third-party store operator',
  false,
  true
)
ON CONFLICT (role_key) DO UPDATE
SET description = EXCLUDED.description,
    requires_step_up = EXCLUDED.requires_step_up,
    is_active = EXCLUDED.is_active;

COMMENT ON TABLE public.staff_provisionable_roles IS
  'Allowlist of role_key values grant_staff_role() may assign. Includes STORE_3RD_PARTY parity for governed 3PGS staff provisioning as of 2026-08-26.';
