-- CORE-HIERARCHY-MAP-01: deterministic commercial company ↔ org-company hierarchy bridge.
--
-- Census (20260906130000):
--   public.companies — B2B commercial spine (orders, wallet, GST, profiles.company_id).
--   public.org_companies — org hierarchy spine (branches, contacts, memberships).
--   org_companies.external_ref — nullable text with unique index; no documented contract
--     binding to public.companies.id and no FK integrity.
--   profiles.company_id, b2b_applications.resolved_company_id — commercial spine only.
--   org_memberships / org_branches — org spine only; no cross-spine FK.
--   GST/name/email identity inference — explicitly out of scope (fail-closed).
--
-- Conclusion: schema mutation required. Smallest canonical representation is an explicit
-- 1:1 link table with FK integrity on both spines. Unlinked commercial companies remain
-- UNLINKED until governed reconciliation inserts a row.
--
-- Merge chronology: Point36 #209 → Point37 #215 → this bridge (stacked on fcf24f5 head).

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE IF NOT EXISTS public.commercial_org_company_links (
  commercial_company_id uuid PRIMARY KEY
    REFERENCES public.companies(id) ON DELETE RESTRICT,
  org_company_id uuid NOT NULL
    REFERENCES public.org_companies(id) ON DELETE RESTRICT,
  link_status text NOT NULL DEFAULT 'active'
    CHECK (link_status IN ('active', 'inactive')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commercial_org_company_links_org_company_id_uidx UNIQUE (org_company_id)
);

COMMENT ON TABLE public.commercial_org_company_links IS
  'Canonical deterministic 1:1 bridge between public.companies (commercial B2B spine) and public.org_companies (org hierarchy spine). Absence of a row means explicit UNLINKED; no fuzzy GST/name/email inference.';

COMMENT ON COLUMN public.commercial_org_company_links.commercial_company_id IS
  'Commercial B2B company authority id from public.companies.';

COMMENT ON COLUMN public.commercial_org_company_links.org_company_id IS
  'Org hierarchy company authority id from public.org_companies.';

COMMENT ON COLUMN public.commercial_org_company_links.link_status IS
  'active = governed link in force; inactive = reconciled but not authoritative until reactivated.';

DROP TRIGGER IF EXISTS trg_commercial_org_company_links_updated_at ON public.commercial_org_company_links;
CREATE TRIGGER trg_commercial_org_company_links_updated_at
  BEFORE UPDATE ON public.commercial_org_company_links
  FOR EACH ROW EXECUTE FUNCTION public.app_verse_set_updated_at();

ALTER TABLE public.commercial_org_company_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS commercial_org_company_links_select ON public.commercial_org_company_links;
CREATE POLICY commercial_org_company_links_select ON public.commercial_org_company_links
FOR SELECT TO authenticated
USING (
  public.has_app_permission(auth.uid(), 'org.read', org_company_id, NULL)
);

DROP POLICY IF EXISTS commercial_org_company_links_manage ON public.commercial_org_company_links;
CREATE POLICY commercial_org_company_links_manage ON public.commercial_org_company_links
FOR ALL TO authenticated
USING (public.has_app_permission(auth.uid(), 'org.manage', org_company_id, NULL))
WITH CHECK (public.has_app_permission(auth.uid(), 'org.manage', org_company_id, NULL));

REVOKE ALL ON TABLE public.commercial_org_company_links FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.commercial_org_company_links TO authenticated;
GRANT ALL ON TABLE public.commercial_org_company_links TO service_role;

CREATE OR REPLACE FUNCTION public.staff_company_hierarchy_v1(p_company_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_commercial public.companies%rowtype;
  v_link public.commercial_org_company_links%rowtype;
  v_org public.org_companies%rowtype;
  v_link_count integer;
  v_branches jsonb := '[]'::jsonb;
  v_contacts jsonb := '[]'::jsonb;
  v_memberships jsonb := '[]'::jsonb;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_company_id IS NULL THEN
    RETURN jsonb_build_object(
      'resolution_status', 'INVALID',
      'commercial_company_id', NULL,
      'reason', 'COMMERCIAL_COMPANY_ID_REQUIRED'
    );
  END IF;

  SELECT * INTO v_commercial
  FROM public.companies c
  WHERE c.id = p_company_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'resolution_status', 'INVALID',
      'commercial_company_id', p_company_id,
      'reason', 'COMMERCIAL_COMPANY_NOT_FOUND'
    );
  END IF;

  SELECT count(*)::integer INTO v_link_count
  FROM public.commercial_org_company_links l
  WHERE l.commercial_company_id = p_company_id;

  IF v_link_count = 0 THEN
    RETURN jsonb_build_object(
      'resolution_status', 'UNLINKED',
      'commercial_company_id', p_company_id,
      'commercial_business_name', v_commercial.business_name,
      'commercial_status', v_commercial.status
    );
  END IF;

  IF v_link_count > 1 THEN
    RETURN jsonb_build_object(
      'resolution_status', 'AMBIGUOUS',
      'commercial_company_id', p_company_id,
      'reason', 'MULTIPLE_COMMERCIAL_LINKS'
    );
  END IF;

  SELECT * INTO v_link
  FROM public.commercial_org_company_links l
  WHERE l.commercial_company_id = p_company_id;

  IF v_link.link_status <> 'active' THEN
    RETURN jsonb_build_object(
      'resolution_status', 'INACTIVE',
      'commercial_company_id', p_company_id,
      'org_company_id', v_link.org_company_id,
      'reason', 'LINK_INACTIVE'
    );
  END IF;

  SELECT * INTO v_org
  FROM public.org_companies oc
  WHERE oc.id = v_link.org_company_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'resolution_status', 'INVALID',
      'commercial_company_id', p_company_id,
      'org_company_id', v_link.org_company_id,
      'reason', 'ORG_COMPANY_NOT_FOUND'
    );
  END IF;

  IF lower(coalesce(v_commercial.status, '')) NOT IN ('active', 'approved')
     OR coalesce(v_commercial.is_frozen, false) THEN
    RETURN jsonb_build_object(
      'resolution_status', 'INACTIVE',
      'commercial_company_id', p_company_id,
      'org_company_id', v_org.id,
      'reason', 'COMMERCIAL_COMPANY_INACTIVE'
    );
  END IF;

  IF lower(coalesce(v_org.status, '')) <> 'active' THEN
    RETURN jsonb_build_object(
      'resolution_status', 'INACTIVE',
      'commercial_company_id', p_company_id,
      'org_company_id', v_org.id,
      'reason', 'ORG_COMPANY_INACTIVE'
    );
  END IF;

  IF NOT public.has_app_permission(v_actor, 'org.read', v_org.id, NULL) THEN
    RAISE EXCEPTION 'org.read required for commercial company hierarchy'
      USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'branch_id', b.id,
      'branch_code', b.branch_code,
      'name', b.name,
      'branch_type', b.branch_type,
      'status', b.status
    )
    ORDER BY b.branch_code NULLS LAST, b.name
  ), '[]'::jsonb)
  INTO v_branches
  FROM public.org_branches b
  WHERE b.company_id = v_org.id
    AND public.has_app_permission(v_actor, 'org.read', v_org.id, b.id);

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'contact_id', c.id,
      'full_name', c.full_name,
      'email', c.email,
      'phone', c.phone,
      'status', c.status
    )
    ORDER BY c.full_name
  ), '[]'::jsonb)
  INTO v_contacts
  FROM public.org_contacts c
  WHERE EXISTS (
    SELECT 1
    FROM public.org_memberships m
    WHERE m.contact_id = c.id
      AND m.company_id = v_org.id
      AND m.status <> 'ended'
  )
    AND public.has_app_permission(v_actor, 'org.read', v_org.id, NULL);

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'membership_id', m.id,
      'status', m.status,
      'contact_id', m.contact_id,
      'user_id', m.user_id,
      'valid_from', m.valid_from,
      'valid_until', m.valid_until,
      'role_keys', (
        SELECT coalesce(jsonb_agg(mr.role_key ORDER BY mr.role_key), '[]'::jsonb)
        FROM public.org_membership_roles mr
        WHERE mr.membership_id = m.id
      ),
      'branch_scope_ids', (
        SELECT coalesce(jsonb_agg(s.branch_id ORDER BY s.branch_id), '[]'::jsonb)
        FROM public.org_membership_branch_scopes s
        WHERE s.membership_id = m.id
      )
    )
    ORDER BY m.created_at
  ), '[]'::jsonb)
  INTO v_memberships
  FROM public.org_memberships m
  WHERE m.company_id = v_org.id
    AND m.status <> 'ended'
    AND public.has_app_permission(v_actor, 'org.read', v_org.id, NULL);

  RETURN jsonb_build_object(
    'resolution_status', 'RESOLVED',
    'commercial_company_id', p_company_id,
    'org_company_id', v_org.id,
    'commercial_business_name', v_commercial.business_name,
    'commercial_status', v_commercial.status,
    'org_company', jsonb_build_object(
      'legal_name', v_org.legal_name,
      'display_name', v_org.display_name,
      'status', v_org.status
    ),
    'branches', v_branches,
    'contacts', v_contacts,
    'memberships', v_memberships
  );
END;
$$;

COMMENT ON FUNCTION public.staff_company_hierarchy_v1(uuid) IS
  'Staff-safe commercial-company → org hierarchy bridge for Central Point60. Input is public.companies.id. Fail-closed auth; RESOLVED/UNLINKED/INACTIVE/INVALID/AMBIGUOUS resolution statuses; branch list respects caller org.read branch scope; excludes commercial wallet/credit/internal fields.';

REVOKE ALL ON FUNCTION public.staff_company_hierarchy_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_company_hierarchy_v1(uuid) TO authenticated, service_role;
