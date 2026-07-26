
-- =========================================================
-- PRIORITY 0: Authorization grants for helper functions
-- =========================================================
GRANT EXECUTE ON FUNCTION public.is_team_member(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_roles() TO authenticated;
GRANT EXECUTE ON FUNCTION public.bootstrap_current_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_oasis_sku(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_alias(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.search_products_with_aliases(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_public_catalogue_channel_data(text) TO authenticated, anon;

-- =========================================================
-- PHASE 1: Additive product columns for PDF import
-- =========================================================
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS source_document text,
  ADD COLUMN IF NOT EXISTS source_page integer,
  ADD COLUMN IF NOT EXISTS source_collection text,
  ADD COLUMN IF NOT EXISTS source_pdf_sku text,
  ADD COLUMN IF NOT EXISTS source_notes text,
  ADD COLUMN IF NOT EXISTS import_confidence text DEFAULT 'needs_review',
  ADD COLUMN IF NOT EXISTS b2b_price_inr numeric,
  ADD COLUMN IF NOT EXISTS export_price_usd numeric,
  ADD COLUMN IF NOT EXISTS carton_dimensions_cm text,
  ADD COLUMN IF NOT EXISTS product_dimensions_cm text,
  ADD COLUMN IF NOT EXISTS gross_weight_kg numeric,
  ADD COLUMN IF NOT EXISTS cbm numeric,
  ADD COLUMN IF NOT EXISTS grammage_g numeric,
  ADD COLUMN IF NOT EXISTS pcs_per_carton numeric,
  ADD COLUMN IF NOT EXISTS avg_qty_per_tray_g numeric,
  ADD COLUMN IF NOT EXISTS qty_per_carton_kg numeric,
  ADD COLUMN IF NOT EXISTS pdf_storage_condition text,
  ADD COLUMN IF NOT EXISTS pdf_shelf_life text,
  ADD COLUMN IF NOT EXISTS pdf_primary_packaging text,
  ADD COLUMN IF NOT EXISTS pdf_secondary_packaging text,
  ADD COLUMN IF NOT EXISTS pdf_status text;

-- Idempotency index for PDF re-imports (partial)
CREATE UNIQUE INDEX IF NOT EXISTS products_pdf_source_unique
  ON public.products (source_document, source_page, source_pdf_sku, product_name, pack_size)
  WHERE source_document IS NOT NULL AND source_pdf_sku IS NOT NULL;

-- =========================================================
-- PHASE 1: Missing SKU code rules
-- =========================================================
INSERT INTO public.sku_code_rules (code_type, code, label, description, sort_order, is_active)
VALUES
  ('category',   'FUS',      'Fusion Sweets',           'Fusion sweets category',     100, true),
  ('packaging',  'PAPERBOX', 'Printed Paper Box',       'Printed paper box pack',     100, true),
  ('packaging',  'CRYSTAL',  'Crystal / Transparent',   'Crystal transparent pack',   101, true),
  ('packaging',  'TIN',      'Tin Pack',                'Tin pack',                   102, true),
  ('packaging',  'RBOX',     'Rigid / Gift Box',        'Rigid gift box',             103, true),
  ('packaging',  'MAPTRAY',  'MAP Tray',                'Modified atmosphere tray',   104, true),
  ('packaging',  'FROZEN',   'Frozen Pack',             'Frozen pack',                105, true)
ON CONFLICT DO NOTHING;

-- Safety net in case unique constraint missing on (code_type, code)
CREATE UNIQUE INDEX IF NOT EXISTS sku_code_rules_type_code_unique
  ON public.sku_code_rules (code_type, code);

-- =========================================================
-- PHASE 1: import_logs table
-- =========================================================
CREATE TABLE IF NOT EXISTS public.import_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_document text,
  source_page integer,
  source_pdf_sku text,
  product_name text,
  pack_size text,
  product_id uuid,
  import_status text,
  warning_notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.import_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Team read import_logs" ON public.import_logs;
CREATE POLICY "Team read import_logs"
  ON public.import_logs FOR SELECT
  TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS "Team write import_logs" ON public.import_logs;
CREATE POLICY "Team write import_logs"
  ON public.import_logs FOR ALL
  TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

CREATE INDEX IF NOT EXISTS import_logs_source_idx
  ON public.import_logs (source_document, source_page, source_pdf_sku);
