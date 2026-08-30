-- Trace / Oasis Label Studio printer authority.
--
-- The legacy Trace bootstrap created ols_printers outside Core migration
-- governance, while the live printer UI persists calibration + bridge settings
-- in a JSON settings column that the bootstrap omitted.  Adopt the table into
-- Core idempotently, reconcile the missing column, and route writes through a
-- fail-closed RPC instead of granting direct table UPDATE access.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.ols_printers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  model text,
  command_lang text CHECK (command_lang IN ('TSPL','ZPL','BROWSER')),
  location text,
  status text DEFAULT 'online',
  settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.ols_printers
  ADD COLUMN IF NOT EXISTS settings jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION public.ols_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  new.updated_at = now();
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS set_updated_at ON public.ols_printers;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.ols_printers
  FOR EACH ROW EXECUTE FUNCTION public.ols_set_updated_at();

ALTER TABLE public.ols_printers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ols_printers FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.ols_printers TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.ols_printers TO service_role;

-- Replace the legacy permissive policies with the canonical internal-read rule.
DROP POLICY IF EXISTS ols_auth_read ON public.ols_printers;
DROP POLICY IF EXISTS ols_auth_write ON public.ols_printers;
DROP POLICY IF EXISTS ols_auth_update ON public.ols_printers;
DROP POLICY IF EXISTS trace_internal_read ON public.ols_printers;
CREATE POLICY trace_internal_read
  ON public.ols_printers
  FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.trace_save_printer_settings_v1(
  p_printer_id uuid,
  p_settings jsonb
)
RETURNS public.ols_printers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_printer public.ols_printers;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'TRACE_PRINTER_SETTINGS_FORBIDDEN' USING ERRCODE = '42501';
  END IF;

  IF p_printer_id IS NULL THEN
    RAISE EXCEPTION 'TRACE_PRINTER_ID_REQUIRED' USING ERRCODE = '22023';
  END IF;

  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'TRACE_PRINTER_SETTINGS_OBJECT_REQUIRED' USING ERRCODE = '22023';
  END IF;

  UPDATE public.ols_printers
     SET settings = p_settings
   WHERE id = p_printer_id
   RETURNING * INTO v_printer;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRACE_PRINTER_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  RETURN v_printer;
END;
$$;

REVOKE ALL ON FUNCTION public.trace_save_printer_settings_v1(uuid, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trace_save_printer_settings_v1(uuid, jsonb)
  TO authenticated, service_role;
