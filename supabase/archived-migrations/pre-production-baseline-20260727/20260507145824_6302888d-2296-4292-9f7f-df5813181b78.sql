-- 1) feature_flags
CREATE TABLE IF NOT EXISTS public.feature_flags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_key text UNIQUE NOT NULL,
  feature_name text NOT NULL,
  description text,
  status text NOT NULL DEFAULT 'planned',
  is_visible boolean NOT NULL DEFAULT false,
  is_enabled boolean NOT NULL DEFAULT false,
  required_role text[] NOT NULL DEFAULT ARRAY['owner','admin']::text[],
  setup_notes text,
  last_tested_at timestamp with time zone,
  last_test_result text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.feature_flags DROP CONSTRAINT IF EXISTS feature_flags_status_check;
ALTER TABLE public.feature_flags ADD CONSTRAINT feature_flags_status_check
  CHECK (status IN ('planned','configured','test_passed','enabled','disabled','error'));
CREATE INDEX IF NOT EXISTS idx_feature_flags_visibility ON public.feature_flags(is_visible, is_enabled, status);

-- 2) integration_settings: extend in-place
ALTER TABLE public.integration_settings RENAME COLUMN key TO integration_key;
ALTER TABLE public.integration_settings RENAME COLUMN label TO display_name;
ALTER TABLE public.integration_settings ADD COLUMN IF NOT EXISTS provider text;
ALTER TABLE public.integration_settings ADD COLUMN IF NOT EXISTS public_config jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.integration_settings ADD COLUMN IF NOT EXISTS secret_required boolean NOT NULL DEFAULT true;
ALTER TABLE public.integration_settings ADD COLUMN IF NOT EXISTS secret_status text NOT NULL DEFAULT 'missing';
ALTER TABLE public.integration_settings ADD COLUMN IF NOT EXISTS test_endpoint text;
ALTER TABLE public.integration_settings ADD COLUMN IF NOT EXISTS last_tested_at timestamp with time zone;
ALTER TABLE public.integration_settings ADD COLUMN IF NOT EXISTS last_test_result jsonb;
ALTER TABLE public.integration_settings ADD COLUMN IF NOT EXISTS created_at timestamp with time zone NOT NULL DEFAULT now();
ALTER TABLE public.integration_settings ADD COLUMN IF NOT EXISTS updated_at timestamp with time zone NOT NULL DEFAULT now();

-- Normalize legacy status values BEFORE applying new constraint
UPDATE public.integration_settings
SET status = CASE
  WHEN status IS NULL THEN 'not_configured'
  WHEN status = 'not_connected' THEN 'not_configured'
  WHEN status NOT IN ('not_configured','configured','test_passed','active','failed') THEN 'not_configured'
  ELSE status
END;
UPDATE public.integration_settings SET display_name = integration_key WHERE display_name IS NULL;

ALTER TABLE public.integration_settings ALTER COLUMN integration_key SET NOT NULL;
ALTER TABLE public.integration_settings ALTER COLUMN display_name SET NOT NULL;
ALTER TABLE public.integration_settings ALTER COLUMN status SET DEFAULT 'not_configured';

ALTER TABLE public.integration_settings DROP CONSTRAINT IF EXISTS integration_settings_status_check;
ALTER TABLE public.integration_settings ADD CONSTRAINT integration_settings_status_check
  CHECK (status IN ('not_configured','configured','test_passed','active','failed'));

CREATE UNIQUE INDEX IF NOT EXISTS integration_settings_integration_key_uidx ON public.integration_settings(integration_key);

-- 3) feature_activation_audit
CREATE TABLE IF NOT EXISTS public.feature_activation_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_key text,
  action text,
  old_status text,
  new_status text,
  performed_by uuid,
  notes text,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_feature_activation_audit_feature_key ON public.feature_activation_audit(feature_key, created_at DESC);

-- 4) RLS
ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feature_activation_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Team can view feature flags" ON public.feature_flags;
CREATE POLICY "Team can view feature flags" ON public.feature_flags
  FOR SELECT TO authenticated USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS "Owner admin manage feature flags" ON public.feature_flags;
CREATE POLICY "Owner admin manage feature flags" ON public.feature_flags
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'owner') OR public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'owner') OR public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Owner admin manage integrations" ON public.integration_settings;
CREATE POLICY "Owner admin manage integrations" ON public.integration_settings
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'owner') OR public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'owner') OR public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Owner admin view audit" ON public.feature_activation_audit;
CREATE POLICY "Owner admin view audit" ON public.feature_activation_audit
  FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'owner') OR public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Owner admin insert audit" ON public.feature_activation_audit;
CREATE POLICY "Owner admin insert audit" ON public.feature_activation_audit
  FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(), 'owner') OR public.has_role(auth.uid(), 'admin'));

-- 5) updated_at triggers
DROP TRIGGER IF EXISTS touch_feature_flags_updated_at ON public.feature_flags;
CREATE TRIGGER touch_feature_flags_updated_at BEFORE UPDATE ON public.feature_flags
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS touch_integration_settings_updated_at ON public.integration_settings;
CREATE TRIGGER touch_integration_settings_updated_at BEFORE UPDATE ON public.integration_settings
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 6) Seed feature flags
INSERT INTO public.feature_flags (feature_key, feature_name, description, status, setup_notes) VALUES
  ('ai_image_studio','AI Image Studio','Generate/clean product photos, backgrounds, hero images, social creatives.','planned','Select provider · add backend secret key · create edge function · test generation · enable feature · expose buttons in Product Media / AI Studio.'),
  ('ai_video_studio','AI Video Studio','Generate short product videos, reels, and catalogue animations.','planned','Select provider · add backend secret key · test render pipeline · enable feature · expose buttons in AI Studio.'),
  ('whatsapp_business_api','WhatsApp Business API','Send catalogue links, proposals, and order follow-ups via approved WhatsApp templates.','planned','Add WhatsApp Business credentials in backend secrets · add phone number ID · register approved templates · test send to admin phone · enable catalogue/proposal send.'),
  ('barcode_label_app','Barcode & Label App','Connect to the Oasis barcode printing app and TSC label printers.','planned','Add barcode app base URL · add printer bridge endpoint · test connection · test product label print · test shipping label print · enable label print buttons.'),
  ('oasis_central_sync','Oasis Central API Sync','Sync products, pricing, MOQ, orders, labels, and catalogue data with main Oasis Central app.','planned','Add Oasis Central API base URL · add service token in backend secrets · test product sync · test pricing/MOQ sync · test order handoff · enable sync buttons.'),
  ('advanced_pdf_proposal','Advanced PDF Proposal','Generate polished commercial proposals with pricing, MOQ, terms, QR, and WhatsApp CTA.','planned','Configure proposal template · test PDF render · enable export button on proposal page.'),
  ('bulk_pdf_import','PDF Catalogue Import','Import products from source PDF catalogues with review before approval.','planned','Upload source PDF · run extractor · review staged rows · approve into products.'),
  ('payment_gateway','Payment Gateway','Razorpay/Stripe payment links for advance or proposal confirmation.','planned','Add Razorpay/Stripe keys in backend secrets · test payment link creation · test webhook · enable proposal payment link.'),
  ('tally_invoice_sync','Tally / Invoice Sync','Sync final invoice, GST, e-way bill, and dispatch billing data.','planned','Add Tally bridge endpoint · test invoice push · test e-way bill reference · enable finance sync.'),
  ('printer_bridge','Printer Bridge','Connect browser app to local label printers through bridge app.','planned','Install bridge app on print PC · add bridge endpoint URL · test print job · enable label print buttons.')
ON CONFLICT (feature_key) DO NOTHING;

-- 7) Seed integration settings rows
INSERT INTO public.integration_settings (integration_key, display_name, provider, secret_required) VALUES
  ('ai_image_studio','AI Image Studio','lovable_ai_gateway',false),
  ('ai_video_studio','AI Video Studio','lovable_ai_gateway',false),
  ('whatsapp_business_api','WhatsApp Business API','meta',true),
  ('barcode_label_app','Barcode & Label App','oasis_barcode',true),
  ('oasis_central_sync','Oasis Central API Sync','oasis_central',true),
  ('payment_gateway','Payment Gateway','razorpay',true),
  ('tally_invoice_sync','Tally / Invoice Sync','tally',true),
  ('printer_bridge','Printer Bridge','tsc_bridge',true)
ON CONFLICT (integration_key) DO NOTHING;