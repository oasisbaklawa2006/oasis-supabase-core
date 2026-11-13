-- AUTH-UAT-03B (#523): revoke canonical Buyer company eligibility when the
-- corresponding public.users identity is explicitly deactivated or soft-deleted.
--
-- Forward-only change. Do not edit the historical 20260807170000 migration.
-- Profile-only legacy Buyers must remain eligible: production includes an
-- approved public.profiles row without a corresponding public.users row.
--
-- Existing profile, company, staff and finance/freeze gates are unchanged.
-- No account/profile/company data is written by this migration.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.customer_buyer_eligible_company_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, public, auth
AS $function$
  SELECT p.company_id
  FROM public.profiles p
  JOIN public.companies c ON c.id = p.company_id
  WHERE p.id = auth.uid()
    AND p.company_id IS NOT NULL
    AND p.is_approved IS TRUE
    AND lower(coalesce(p.status, '')) = 'approved'
    AND lower(coalesce(p.role, '')) IN ('b2b_buyer', 'buyer')
    AND NOT public.is_staff_role(p.role)
    AND NOT coalesce(public.is_internal_staff(auth.uid()), false)
    AND lower(coalesce(c.status, '')) IN ('active', 'approved')
    AND coalesce(c.is_frozen, false) IS FALSE
    -- A still-valid JWT cannot override a later governed user deactivation.
    -- NOT EXISTS preserves authorized legacy profile-only Buyer identities.
    AND NOT EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = p.id
        AND (u.is_active IS FALSE OR u.deleted_at IS NOT NULL)
    )
  LIMIT 1;
$function$;

COMMENT ON FUNCTION public.customer_buyer_eligible_company_id() IS
  'Canonical approved Buyer-company resolver. Denies internal staff, unapproved profiles, inactive/frozen companies and linked public.users identities that are explicitly inactive or soft-deleted. Preserves approved legacy profiles without public.users rows.';

-- Preserve the original execution boundary, including after an OR REPLACE.
REVOKE ALL ON FUNCTION public.customer_buyer_eligible_company_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_buyer_eligible_company_id() TO authenticated, service_role;
