-- Point 25 clean-replay compatibility baseline.
-- The governed buckets pre-date the Core migration chain in production.
-- Reconcile every governed bucket identity and visibility to the approved contract.

insert into storage.buckets (id, name, public)
values
  ('product-images', 'product-images', true),
  ('product-media', 'product-media', true),
  ('receipts', 'receipts', false),
  ('trade-documents', 'trade-documents', false),
  ('trade_documents', 'trade_documents', false),
  ('final-invoices', 'final-invoices', false),
  ('proforma-invoices', 'proforma-invoices', false),
  ('whatsapp_attachments', 'whatsapp_attachments', false)
on conflict (id) do update
set name = excluded.name,
    public = excluded.public,
    updated_at = now();
