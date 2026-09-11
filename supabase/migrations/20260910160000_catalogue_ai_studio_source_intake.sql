-- Catalogue source intake for AI Studio.
--
-- Purpose:
--   * accept approved catalogue/source documents into a governed staging surface;
--   * preserve raw source evidence and normalized candidate data;
--   * optionally link an intake entry to an EXISTING product;
--   * keep product creation/publishing entirely out of this migration.
--
-- Non-negotiable boundary:
--   NOTHING in this migration inserts, updates, deletes, or publishes public.products.
--   A source entry may exist with matched_product_id = NULL indefinitely. Promotion into
--   product master remains a separate, explicit human-authorized workflow.

-- =============================================================================
-- 1. Source batches: one durable record per imported catalogue/document revision.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.catalogue_source_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_provider text NOT NULL,
  source_document_id text NULL,
  source_document_name text NOT NULL,
  source_revision text NULL,
  source_hash text NULL,
  dedupe_key text NOT NULL,
  status text NOT NULL DEFAULT 'RECEIVED'
    CHECK (status IN ('RECEIVED', 'PARSING', 'READY_FOR_REVIEW', 'REVIEWED', 'FAILED', 'ARCHIVED')),
  source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  imported_by uuid NULL,
  imported_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalogue_source_batches_provider_nonblank
    CHECK (btrim(source_provider) <> ''),
  CONSTRAINT catalogue_source_batches_name_nonblank
    CHECK (btrim(source_document_name) <> ''),
  CONSTRAINT catalogue_source_batches_dedupe_nonblank
    CHECK (btrim(dedupe_key) <> ''),
  CONSTRAINT catalogue_source_batches_dedupe_unique UNIQUE (dedupe_key)
);

CREATE INDEX IF NOT EXISTS idx_catalogue_source_batches_status
  ON public.catalogue_source_batches (status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_catalogue_source_batches_provider_document
  ON public.catalogue_source_batches (source_provider, source_document_id, created_at DESC);

COMMENT ON TABLE public.catalogue_source_batches IS
  'Governed source-document intake for Catalogue AI Studio. Stores catalogue/document provenance only; never creates products.';

COMMENT ON COLUMN public.catalogue_source_batches.dedupe_key IS
  'Caller-supplied stable idempotency key for one source document/revision. Re-importing the same source must reuse the same key.';

-- =============================================================================
-- 2. Source entries: catalogue rows/pages/items before product-master approval.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.catalogue_source_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.catalogue_source_batches(id) ON DELETE CASCADE,
  source_entry_key text NOT NULL,
  source_page_number integer NULL CHECK (source_page_number IS NULL OR source_page_number > 0),
  source_title text NULL,
  source_sku text NULL,
  source_slug text NULL,

  -- Immutable-ish evidence supplied by the importer and a separate normalized candidate.
  -- The candidate is NOT product master and carries no commerce authority by itself.
  raw_source_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  candidate_product_data jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Optional link to an already-existing product. NULL is the normal state for a new
  -- catalogue entry until a human deliberately matches it.
  matched_product_id uuid NULL,
  match_confidence numeric(5,4) NULL
    CHECK (match_confidence IS NULL OR (match_confidence >= 0 AND match_confidence <= 1)),

  status text NOT NULL DEFAULT 'STAGED'
    CHECK (status IN ('STAGED', 'MATCHED_EXISTING', 'APPROVED_FOR_DRAFT', 'IGNORED')),
  review_note text NULL,
  reviewed_by uuid NULL,
  reviewed_at timestamptz NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT catalogue_source_entries_key_nonblank
    CHECK (btrim(source_entry_key) <> ''),
  CONSTRAINT catalogue_source_entries_batch_key_unique
    UNIQUE (batch_id, source_entry_key),
  CONSTRAINT catalogue_source_entries_match_state_check CHECK (
    (status = 'STAGED' AND matched_product_id IS NULL)
    OR (status = 'MATCHED_EXISTING' AND matched_product_id IS NOT NULL)
    OR (status = 'APPROVED_FOR_DRAFT' AND matched_product_id IS NOT NULL)
    OR status = 'IGNORED'
  ),
  CONSTRAINT catalogue_source_entries_review_state_check CHECK (
    (status IN ('STAGED', 'MATCHED_EXISTING') AND reviewed_at IS NULL)
    OR (status IN ('APPROVED_FOR_DRAFT', 'IGNORED') AND reviewed_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_catalogue_source_entries_batch
  ON public.catalogue_source_entries (batch_id, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_catalogue_source_entries_status
  ON public.catalogue_source_entries (status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_catalogue_source_entries_match
  ON public.catalogue_source_entries (matched_product_id)
  WHERE matched_product_id IS NOT NULL;

COMMENT ON TABLE public.catalogue_source_entries IS
  'Staged catalogue/source entries for AI Studio review. Entries may remain unmatched; no row has authority to create or publish a product.';

COMMENT ON COLUMN public.catalogue_source_entries.candidate_product_data IS
  'Normalized candidate fields for review only. This JSON is not operational product/price/stock authority.';

COMMENT ON COLUMN public.catalogue_source_entries.matched_product_id IS
  'Nullable reference to an EXISTING product only. NULL is valid and does not imply a missing product must be created.';

COMMENT ON COLUMN public.catalogue_source_entries.status IS
  'APPROVED_FOR_DRAFT means approved to start/edit AI Studio copy for an already-existing product; it is NOT approval to create a product.';

-- A product-master deletion must never be blocked by source-staging history. When
-- the FK performs ON DELETE SET NULL, demote any match-dependent state before the
-- row CHECK constraints are evaluated. This preserves both product independence
-- and the invariant that MATCHED/APPROVED rows always reference an existing product.
CREATE OR REPLACE FUNCTION public.catalogue_source_demote_dereferenced_entry()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.matched_product_id IS NOT NULL
     AND NEW.matched_product_id IS NULL
     AND OLD.status IN ('MATCHED_EXISTING', 'APPROVED_FOR_DRAFT') THEN
    NEW.status := 'STAGED';
    NEW.reviewed_by := NULL;
    NEW.reviewed_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_catalogue_source_entries_dereference
  ON public.catalogue_source_entries;
CREATE TRIGGER trg_catalogue_source_entries_dereference
  BEFORE UPDATE OF matched_product_id ON public.catalogue_source_entries
  FOR EACH ROW
  EXECUTE FUNCTION public.catalogue_source_demote_dereferenced_entry();

-- Human attribution fields are provenance, not editable labels. Authenticated
-- staff may set reviewed_by only to themselves on first review and may not rewrite
-- existing attribution. Service/database authority retains repair capability.
CREATE OR REPLACE FUNCTION public.catalogue_source_protect_attribution()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_user IN ('postgres', 'service_role') OR coalesce(auth.role(), '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'catalogue_source_batches'
     AND NEW.imported_by IS DISTINCT FROM OLD.imported_by THEN
    RAISE EXCEPTION 'CATALOGUE_SOURCE_IMPORTED_BY_IMMUTABLE'
      USING ERRCODE = '42501';
  END IF;

  IF TG_TABLE_NAME = 'catalogue_source_entries'
     AND NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by THEN
    IF OLD.reviewed_by IS NOT NULL
       OR (NEW.reviewed_by IS NOT NULL AND NEW.reviewed_by IS DISTINCT FROM auth.uid()) THEN
      RAISE EXCEPTION 'CATALOGUE_SOURCE_REVIEWED_BY_FORBIDDEN'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_catalogue_source_batches_attribution
  ON public.catalogue_source_batches;
CREATE TRIGGER trg_catalogue_source_batches_attribution
  BEFORE UPDATE OF imported_by ON public.catalogue_source_batches
  FOR EACH ROW
  EXECUTE FUNCTION public.catalogue_source_protect_attribution();

DROP TRIGGER IF EXISTS trg_catalogue_source_entries_attribution
  ON public.catalogue_source_entries;
CREATE TRIGGER trg_catalogue_source_entries_attribution
  BEFORE UPDATE OF reviewed_by ON public.catalogue_source_entries
  FOR EACH ROW
  EXECUTE FUNCTION public.catalogue_source_protect_attribution();

-- Add the optional product link only when public.products is present. This mirrors the
-- existing Catalogue AI Studio migration's replay-safe behavior.
DO $$
DECLARE
  rel_entries constant oid := 'public.catalogue_source_entries'::regclass::oid;
  orphan_count bigint;
BEGIN
  IF to_regclass('public.products') IS NULL THEN
    RAISE NOTICE 'Skipping catalogue_source_entries_matched_product_id_fkey: public.products missing';
  ELSIF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conrelid = rel_entries
      AND c.conname = 'catalogue_source_entries_matched_product_id_fkey'
  ) THEN
    SELECT count(*) INTO orphan_count
    FROM public.catalogue_source_entries e
    WHERE e.matched_product_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.products p WHERE p.id = e.matched_product_id
      );

    IF orphan_count = 0 THEN
      ALTER TABLE public.catalogue_source_entries
        ADD CONSTRAINT catalogue_source_entries_matched_product_id_fkey
        FOREIGN KEY (matched_product_id) REFERENCES public.products(id) ON DELETE SET NULL;
    ELSE
      RAISE NOTICE 'Skipping catalogue_source_entries_matched_product_id_fkey: % orphan row(s)', orphan_count;
    END IF;
  END IF;
END $$;

-- =============================================================================
-- 3. Append-only decision/import audit.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.catalogue_source_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.catalogue_source_batches(id) ON DELETE CASCADE,
  entry_id uuid NULL REFERENCES public.catalogue_source_entries(id) ON DELETE CASCADE,
  action text NOT NULL,
  from_status text NULL,
  to_status text NULL,
  actor_id uuid NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalogue_source_audit_action_nonblank CHECK (btrim(action) <> '')
);

CREATE INDEX IF NOT EXISTS idx_catalogue_source_audit_batch
  ON public.catalogue_source_audit_log (batch_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_catalogue_source_audit_entry
  ON public.catalogue_source_audit_log (entry_id, created_at DESC)
  WHERE entry_id IS NOT NULL;

COMMENT ON TABLE public.catalogue_source_audit_log IS
  'Append-only audit trail for catalogue source ingestion, matching and review decisions. No product-master mutation authority.';

-- =============================================================================
-- 4. Timestamp triggers.
-- =============================================================================
DROP TRIGGER IF EXISTS trg_catalogue_source_batches_touch ON public.catalogue_source_batches;
CREATE TRIGGER trg_catalogue_source_batches_touch
  BEFORE UPDATE ON public.catalogue_source_batches
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS trg_catalogue_source_entries_touch ON public.catalogue_source_entries;
CREATE TRIGGER trg_catalogue_source_entries_touch
  BEFORE UPDATE ON public.catalogue_source_entries
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- =============================================================================
-- 5. RLS and grants.
--    Anonymous users have no access. Team members can inspect/import/review staging
--    rows but cannot delete history. Service role is retained for controlled importers.
-- =============================================================================
ALTER TABLE public.catalogue_source_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_source_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_source_audit_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.catalogue_source_batches FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.catalogue_source_entries FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.catalogue_source_audit_log FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.catalogue_source_batches TO service_role;
GRANT ALL ON TABLE public.catalogue_source_entries TO service_role;
GRANT ALL ON TABLE public.catalogue_source_audit_log TO service_role;

GRANT SELECT, INSERT, UPDATE ON TABLE public.catalogue_source_batches TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.catalogue_source_entries TO authenticated;
GRANT SELECT, INSERT ON TABLE public.catalogue_source_audit_log TO authenticated;

DROP POLICY IF EXISTS catalogue_source_batches_service_role ON public.catalogue_source_batches;
CREATE POLICY catalogue_source_batches_service_role
  ON public.catalogue_source_batches FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalogue_source_batches_staff_select ON public.catalogue_source_batches;
CREATE POLICY catalogue_source_batches_staff_select
  ON public.catalogue_source_batches FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_source_batches_staff_insert ON public.catalogue_source_batches;
CREATE POLICY catalogue_source_batches_staff_insert
  ON public.catalogue_source_batches FOR INSERT TO authenticated
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND status = 'RECEIVED'
    AND (imported_by IS NULL OR imported_by = auth.uid())
  );

DROP POLICY IF EXISTS catalogue_source_batches_staff_update ON public.catalogue_source_batches;
CREATE POLICY catalogue_source_batches_staff_update
  ON public.catalogue_source_batches FOR UPDATE TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_source_entries_service_role ON public.catalogue_source_entries;
CREATE POLICY catalogue_source_entries_service_role
  ON public.catalogue_source_entries FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalogue_source_entries_staff_select ON public.catalogue_source_entries;
CREATE POLICY catalogue_source_entries_staff_select
  ON public.catalogue_source_entries FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_source_entries_staff_insert ON public.catalogue_source_entries;
CREATE POLICY catalogue_source_entries_staff_insert
  ON public.catalogue_source_entries FOR INSERT TO authenticated
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND status = 'STAGED'
    AND matched_product_id IS NULL
    AND reviewed_by IS NULL
    AND reviewed_at IS NULL
  );

DROP POLICY IF EXISTS catalogue_source_entries_staff_update ON public.catalogue_source_entries;
CREATE POLICY catalogue_source_entries_staff_update
  ON public.catalogue_source_entries FOR UPDATE TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND (reviewed_by IS NULL OR reviewed_by = auth.uid())
  );

DROP POLICY IF EXISTS catalogue_source_audit_service_role ON public.catalogue_source_audit_log;
CREATE POLICY catalogue_source_audit_service_role
  ON public.catalogue_source_audit_log FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalogue_source_audit_staff_select ON public.catalogue_source_audit_log;
CREATE POLICY catalogue_source_audit_staff_select
  ON public.catalogue_source_audit_log FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_source_audit_staff_insert ON public.catalogue_source_audit_log;
CREATE POLICY catalogue_source_audit_staff_insert
  ON public.catalogue_source_audit_log FOR INSERT TO authenticated
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND (actor_id IS NULL OR actor_id = auth.uid())
  );

-- No authenticated DELETE policies are intentionally defined for any intake table.
-- No product mutation function, trigger, publication function, or product insert is created here.
