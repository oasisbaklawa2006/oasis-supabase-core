-- Catalogue AI-Studio draft governance schema.
-- Persists Catalogue AI-Studio drafts with versioning, review workflow, and audit history.
-- Does NOT call any external AI/image/PDF/WhatsApp API.
-- Does NOT mutate products, price, SKU, media, orders, finance, dispatch, or WhatsApp state.

-- =============================================================================
-- 1. catalogue_ai_studio_drafts
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.catalogue_ai_studio_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL,
  version_number integer NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT', 'UNDER_REVIEW', 'APPROVED', 'REJECTED')),

  catalogue_title text NOT NULL DEFAULT '',
  short_description text NOT NULL DEFAULT '',
  long_description text NOT NULL DEFAULT '',
  b2b_sales_copy text NOT NULL DEFAULT '',
  export_catalogue_copy text NOT NULL DEFAULT '',
  whatsapp_product_message text NOT NULL DEFAULT '',
  hindi_description text NOT NULL DEFAULT '',
  storage_shelf_life_copy text NOT NULL DEFAULT '',

  hero_image_prompt text NOT NULL DEFAULT '',
  square_image_prompt text NOT NULL DEFAULT '',
  closeup_image_prompt text NOT NULL DEFAULT '',
  packaging_image_prompt text NOT NULL DEFAULT '',
  lifestyle_image_prompt text NOT NULL DEFAULT '',

  export_bundle_preview text NOT NULL DEFAULT '',

  source_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,

  created_by uuid NULL,
  reviewed_by uuid NULL,
  reviewed_at timestamptz NULL,
  rejection_reason text NULL,
  published_at timestamptz NULL,
  published_by uuid NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_catalogue_ai_studio_drafts_product
  ON public.catalogue_ai_studio_drafts (product_id, version_number DESC);

CREATE INDEX IF NOT EXISTS idx_catalogue_ai_studio_drafts_status
  ON public.catalogue_ai_studio_drafts (status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_catalogue_ai_studio_drafts_created_at
  ON public.catalogue_ai_studio_drafts (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_catalogue_ai_studio_drafts_updated_at
  ON public.catalogue_ai_studio_drafts (updated_at DESC);

-- Only one open (non-terminal) draft per product at a time — a new version can only be
-- started once the current one is APPROVED or REJECTED, matching the workflow rules.
CREATE UNIQUE INDEX IF NOT EXISTS idx_catalogue_ai_studio_drafts_one_open_per_product
  ON public.catalogue_ai_studio_drafts (product_id)
  WHERE status IN ('DRAFT', 'UNDER_REVIEW');

CREATE UNIQUE INDEX IF NOT EXISTS idx_catalogue_ai_studio_drafts_product_version_unique
  ON public.catalogue_ai_studio_drafts (product_id, version_number);

COMMENT ON TABLE public.catalogue_ai_studio_drafts IS
  'Catalogue AI-Studio draft persistence, versioning, and review workflow. No external AI call and no product mutation.';

-- =============================================================================
-- 2. catalogue_ai_studio_draft_audit_log (append-only)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.catalogue_ai_studio_draft_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  draft_id uuid NOT NULL REFERENCES public.catalogue_ai_studio_drafts (id) ON DELETE CASCADE,
  action text NOT NULL,
  from_status text NULL,
  to_status text NULL,
  actor_id uuid NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_catalogue_ai_studio_draft_audit_draft
  ON public.catalogue_ai_studio_draft_audit_log (draft_id, created_at DESC);

COMMENT ON TABLE public.catalogue_ai_studio_draft_audit_log IS
  'Append-only audit trail for catalogue_ai_studio_drafts workflow transitions (save, submit, approve, reject, publish).';

-- =============================================================================
-- 3. Foreign key to products (conditional — skip if orphans or missing parent)
-- =============================================================================
DO $$
DECLARE
  rel_drafts constant oid := 'public.catalogue_ai_studio_drafts'::regclass::oid;
  orphan_count bigint;
BEGIN
  IF to_regclass('public.products') IS NULL THEN
    RAISE NOTICE 'Skipping catalogue_ai_studio_drafts_product_id_fkey: public.products missing';
  ELSIF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = rel_drafts AND c.conname = 'catalogue_ai_studio_drafts_product_id_fkey'
  ) THEN
    SELECT COUNT(*) INTO orphan_count
    FROM public.catalogue_ai_studio_drafts d
    WHERE NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = d.product_id);

    IF orphan_count = 0 THEN
      ALTER TABLE public.catalogue_ai_studio_drafts
        ADD CONSTRAINT catalogue_ai_studio_drafts_product_id_fkey
        FOREIGN KEY (product_id) REFERENCES public.products (id) ON DELETE CASCADE;
    ELSE
      RAISE NOTICE 'Skipping catalogue_ai_studio_drafts_product_id_fkey: % orphan row(s)', orphan_count;
    END IF;
  END IF;
END $$;

-- =============================================================================
-- 4. updated_at trigger
-- =============================================================================
DROP TRIGGER IF EXISTS trg_catalogue_ai_studio_drafts_touch ON public.catalogue_ai_studio_drafts;
CREATE TRIGGER trg_catalogue_ai_studio_drafts_touch
  BEFORE UPDATE ON public.catalogue_ai_studio_drafts
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- =============================================================================
-- 5. RLS — team members only, using the shared backend authority helper.
--    No DELETE policy for authenticated users: drafts/audit rows are retained for history.
-- =============================================================================
ALTER TABLE public.catalogue_ai_studio_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_ai_studio_draft_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS catalogue_ai_studio_drafts_service_role ON public.catalogue_ai_studio_drafts;
CREATE POLICY catalogue_ai_studio_drafts_service_role
  ON public.catalogue_ai_studio_drafts FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalogue_ai_studio_drafts_staff_select ON public.catalogue_ai_studio_drafts;
CREATE POLICY catalogue_ai_studio_drafts_staff_select
  ON public.catalogue_ai_studio_drafts FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_ai_studio_drafts_staff_insert ON public.catalogue_ai_studio_drafts;
CREATE POLICY catalogue_ai_studio_drafts_staff_insert
  ON public.catalogue_ai_studio_drafts FOR INSERT TO authenticated
  WITH CHECK (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_ai_studio_drafts_staff_update ON public.catalogue_ai_studio_drafts;
CREATE POLICY catalogue_ai_studio_drafts_staff_update
  ON public.catalogue_ai_studio_drafts FOR UPDATE TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_ai_studio_draft_audit_service_role ON public.catalogue_ai_studio_draft_audit_log;
CREATE POLICY catalogue_ai_studio_draft_audit_service_role
  ON public.catalogue_ai_studio_draft_audit_log FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalogue_ai_studio_draft_audit_staff_select ON public.catalogue_ai_studio_draft_audit_log;
CREATE POLICY catalogue_ai_studio_draft_audit_staff_select
  ON public.catalogue_ai_studio_draft_audit_log FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_ai_studio_draft_audit_staff_insert ON public.catalogue_ai_studio_draft_audit_log;
CREATE POLICY catalogue_ai_studio_draft_audit_staff_insert
  ON public.catalogue_ai_studio_draft_audit_log FOR INSERT TO authenticated
  WITH CHECK (public.is_team_member(auth.uid()));
