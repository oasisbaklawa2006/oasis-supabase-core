ALTER TABLE public.catalogues
  ADD COLUMN IF NOT EXISTS proposal_validity_note text,
  ADD COLUMN IF NOT EXISTS proposal_tax_note text,
  ADD COLUMN IF NOT EXISTS proposal_transport_note text,
  ADD COLUMN IF NOT EXISTS proposal_customization_note text,
  ADD COLUMN IF NOT EXISTS proposal_footer_note text,
  ADD COLUMN IF NOT EXISTS proposal_whatsapp_message text;