
CREATE TABLE IF NOT EXISTS public.product_bom_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  child_product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  saleable_product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  component_type text NOT NULL DEFAULT 'product',
  component_name text,
  quantity numeric NOT NULL DEFAULT 1,
  unit text NOT NULL DEFAULT 'pc',
  cost_per_unit numeric,
  total_cost numeric,
  notes text,
  sort_order integer NOT NULL DEFAULT 0,

  visibility_scope text NOT NULL DEFAULT 'internal_only',
  show_to_customer boolean NOT NULL DEFAULT false,
  show_in_public_catalogue boolean NOT NULL DEFAULT false,
  show_in_pdf_catalogue boolean NOT NULL DEFAULT false,
  show_on_label boolean NOT NULL DEFAULT false,

  is_individually_saleable boolean NOT NULL DEFAULT false,
  internal_component_only boolean NOT NULL DEFAULT true,

  source_department text,
  production_department text,
  issue_to_department text DEFAULT 'packing_assembly',
  required_before_assembly boolean NOT NULL DEFAULT true,
  lead_time_days integer,
  stock_check_required boolean NOT NULL DEFAULT true,
  is_packaging_component boolean NOT NULL DEFAULT false,
  is_private_label_component boolean NOT NULL DEFAULT false,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.product_bom_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Team read bom"
  ON public.product_bom_items FOR SELECT
  TO authenticated
  USING (public.is_team_member(auth.uid()));

CREATE POLICY "Team write bom"
  ON public.product_bom_items FOR ALL
  TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

CREATE INDEX IF NOT EXISTS idx_bom_parent ON public.product_bom_items(parent_product_id);
CREATE INDEX IF NOT EXISTS idx_bom_child ON public.product_bom_items(child_product_id);
CREATE INDEX IF NOT EXISTS idx_bom_source_dept ON public.product_bom_items(source_department);
CREATE INDEX IF NOT EXISTS idx_bom_prod_dept ON public.product_bom_items(production_department);

CREATE TRIGGER trg_bom_touch
  BEFORE UPDATE ON public.product_bom_items
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
