
-- product_moq_rules
CREATE TABLE IF NOT EXISTS public.product_moq_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  channel text NOT NULL,
  customer_type text,
  moq_applicable boolean NOT NULL DEFAULT true,
  moq_value numeric,
  moq_uom text,
  increment_value numeric,
  increment_uom text,
  min_carton_qty numeric,
  carton_logic text,
  allow_override boolean NOT NULL DEFAULT false,
  override_requires_approval boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_moq_rule_product_channel_ct
  ON public.product_moq_rules (product_id, channel, COALESCE(customer_type, ''));
CREATE INDEX IF NOT EXISTS idx_moq_product ON public.product_moq_rules(product_id);
CREATE INDEX IF NOT EXISTS idx_moq_channel ON public.product_moq_rules(channel);

ALTER TABLE public.product_moq_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Team read moq" ON public.product_moq_rules;
CREATE POLICY "Team read moq" ON public.product_moq_rules
  FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
DROP POLICY IF EXISTS "Team write moq" ON public.product_moq_rules;
CREATE POLICY "Team write moq" ON public.product_moq_rules
  FOR ALL TO authenticated USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

DROP TRIGGER IF EXISTS trg_moq_touch ON public.product_moq_rules;
CREATE TRIGGER trg_moq_touch BEFORE UPDATE ON public.product_moq_rules
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- product_pricing_rules
CREATE TABLE IF NOT EXISTS public.product_pricing_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  price_channel text NOT NULL,
  price_type text NOT NULL DEFAULT 'fixed_price',
  base_price numeric,
  discount_percent numeric,
  calculated_price numeric,
  currency text NOT NULL DEFAULT 'INR',
  uom text,
  tax_inclusive boolean NOT NULL DEFAULT false,
  gst_rate numeric,
  valid_from date,
  valid_until date,
  approval_status text NOT NULL DEFAULT 'draft',
  approved_by uuid,
  approved_at timestamptz,
  notes text,
  source text NOT NULL DEFAULT 'catalogue_local',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_price_rule_product_channel
  ON public.product_pricing_rules (product_id, price_channel);
CREATE INDEX IF NOT EXISTS idx_price_product ON public.product_pricing_rules(product_id);
CREATE INDEX IF NOT EXISTS idx_price_channel ON public.product_pricing_rules(price_channel);
CREATE INDEX IF NOT EXISTS idx_price_approval ON public.product_pricing_rules(approval_status);

ALTER TABLE public.product_pricing_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Team read pricing" ON public.product_pricing_rules;
CREATE POLICY "Team read pricing" ON public.product_pricing_rules
  FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));
DROP POLICY IF EXISTS "Team write pricing" ON public.product_pricing_rules;
CREATE POLICY "Team write pricing" ON public.product_pricing_rules
  FOR ALL TO authenticated USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

DROP TRIGGER IF EXISTS trg_pricing_touch ON public.product_pricing_rules;
CREATE TRIGGER trg_pricing_touch BEFORE UPDATE ON public.product_pricing_rules
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- catalogue extensions
ALTER TABLE public.catalogues
  ADD COLUMN IF NOT EXISTS target_customer_channel text DEFAULT 'price_hidden',
  ADD COLUMN IF NOT EXISTS show_price boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS show_mrp boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS show_discount boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS show_price_label text;
