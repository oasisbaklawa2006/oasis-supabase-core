-- Follow-up for 20260910160000_catalogue_ai_studio_source_intake.sql and
-- 20260910160100_catalogue_ai_studio_source_intake_hardening.sql.
--
-- The attribution trigger is shared by two tables with different row shapes.
-- Branch on TG_TABLE_NAME before dereferencing table-specific NEW/OLD fields so
-- PostgreSQL never attempts to resolve a field that does not exist on that row.

CREATE OR REPLACE FUNCTION public.catalogue_source_protect_attribution()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_user IN ('postgres', 'service_role')
     OR coalesce(auth.role(), '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'catalogue_source_batches' THEN
    IF NEW.imported_by IS DISTINCT FROM OLD.imported_by THEN
      RAISE EXCEPTION 'CATALOGUE_SOURCE_IMPORTED_BY_IMMUTABLE'
        USING ERRCODE = '42501';
    END IF;
  ELSIF TG_TABLE_NAME = 'catalogue_source_entries' THEN
    IF NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by THEN
      IF OLD.reviewed_by IS NOT NULL
         OR (
           NEW.reviewed_by IS NOT NULL
           AND NEW.reviewed_by IS DISTINCT FROM auth.uid()
         ) THEN
        RAISE EXCEPTION 'CATALOGUE_SOURCE_REVIEWED_BY_FORBIDDEN'
          USING ERRCODE = '42501';
      END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'CATALOGUE_SOURCE_ATTRIBUTION_TRIGGER_TABLE_UNEXPECTED'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;
