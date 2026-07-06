-- Batch B: Oasis product classification schema (all fields nullable, non-breaking)
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS product_class text,
  ADD COLUMN IF NOT EXISTS main_department text,
  ADD COLUMN IF NOT EXISTS production_department text,
  ADD COLUMN IF NOT EXISTS primary_uom text,
  ADD COLUMN IF NOT EXISTS b2b_uom text,
  ADD COLUMN IF NOT EXISTS retail_uom text,
  ADD COLUMN IF NOT EXISTS price_basis text,
  ADD COLUMN IF NOT EXISTS b2b_price_basis text,
  ADD COLUMN IF NOT EXISTS retail_price_basis text,
  ADD COLUMN IF NOT EXISTS unit_conversion_note text,
  ADD COLUMN IF NOT EXISTS moq_rule_type text,
  ADD COLUMN IF NOT EXISTS moq_value numeric,
  ADD COLUMN IF NOT EXISTS moq_uom text,
  ADD COLUMN IF NOT EXISTS increment_value numeric,
  ADD COLUMN IF NOT EXISTS increment_uom text,
  ADD COLUMN IF NOT EXISTS fixed_carton_required boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS carton_qty numeric,
  ADD COLUMN IF NOT EXISTS carton_uom text,
  ADD COLUMN IF NOT EXISTS master_carton_qty numeric,
  ADD COLUMN IF NOT EXISTS master_carton_uom text,
  ADD COLUMN IF NOT EXISTS dimension_l_cm numeric,
  ADD COLUMN IF NOT EXISTS dimension_w_cm numeric,
  ADD COLUMN IF NOT EXISTS dimension_h_cm numeric,
  ADD COLUMN IF NOT EXISTS private_label_allowed boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS private_label_moq numeric,
  ADD COLUMN IF NOT EXISTS private_label_moq_uom text,
  ADD COLUMN IF NOT EXISTS private_label_cost_per_unit numeric,
  ADD COLUMN IF NOT EXISTS private_label_upfront_cost numeric,
  ADD COLUMN IF NOT EXISTS customization_allowed boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS customization_note text,
  ADD COLUMN IF NOT EXISTS customization_caution text,
  ADD COLUMN IF NOT EXISTS bom_required boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS pricing_notes text,
  ADD COLUMN IF NOT EXISTS operational_notes text,
  ADD COLUMN IF NOT EXISTS frozen_shelf_life_days integer,
  ADD COLUMN IF NOT EXISTS post_processing_shelf_life_days integer,
  ADD COLUMN IF NOT EXISTS temperature_requirement text,
  ADD COLUMN IF NOT EXISTS thawing_instruction text,
  ADD COLUMN IF NOT EXISTS material_type text,
  ADD COLUMN IF NOT EXISTS color_finish_notes text,
  ADD COLUMN IF NOT EXISTS pcs_per_pack numeric,
  ADD COLUMN IF NOT EXISTS pieces_per_kg numeric,
  ADD COLUMN IF NOT EXISTS approximate_piece_weight_g numeric;

-- Helpful indexes for filters/search introduced in Batch D
CREATE INDEX IF NOT EXISTS idx_products_product_class ON public.products(product_class);
CREATE INDEX IF NOT EXISTS idx_products_main_department ON public.products(main_department);
CREATE INDEX IF NOT EXISTS idx_products_production_department ON public.products(production_department);

-- Validation trigger: if main_department = 'ready_goods_store', production_department is required
CREATE OR REPLACE FUNCTION public.validate_product_department()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.main_department = 'ready_goods_store'
     AND (NEW.production_department IS NULL OR NEW.production_department = '') THEN
    RAISE EXCEPTION 'production_department is required when main_department is ready_goods_store';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_product_department ON public.products;
CREATE TRIGGER trg_validate_product_department
BEFORE INSERT OR UPDATE OF main_department, production_department ON public.products
FOR EACH ROW EXECUTE FUNCTION public.validate_product_department();