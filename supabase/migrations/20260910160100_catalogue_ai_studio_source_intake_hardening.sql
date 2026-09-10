-- Follow-up hardening for 20260910160000_catalogue_ai_studio_source_intake.sql.
--
-- Supabase Preview may already have recorded the original migration filename before
-- review fixes land. Keep this migration idempotent so preview and clean replay both
-- converge on the same final product-dereference and attribution-integrity contract.

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

DROP POLICY IF EXISTS catalogue_source_batches_staff_insert ON public.catalogue_source_batches;
CREATE POLICY catalogue_source_batches_staff_insert
  ON public.catalogue_source_batches FOR INSERT TO authenticated
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND status = 'RECEIVED'
    AND (imported_by IS NULL OR imported_by = auth.uid())
  );

DROP POLICY IF EXISTS catalogue_source_entries_staff_update ON public.catalogue_source_entries;
CREATE POLICY catalogue_source_entries_staff_update
  ON public.catalogue_source_entries FOR UPDATE TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND (reviewed_by IS NULL OR reviewed_by = auth.uid())
  );

DROP POLICY IF EXISTS catalogue_source_audit_staff_insert ON public.catalogue_source_audit_log;
CREATE POLICY catalogue_source_audit_staff_insert
  ON public.catalogue_source_audit_log FOR INSERT TO authenticated
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND (actor_id IS NULL OR actor_id = auth.uid())
  );
