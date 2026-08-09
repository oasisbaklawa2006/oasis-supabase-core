-- Non-sensitive infrastructure/reference seed for deterministic local and
-- preview environments. No production users, orders, messages, files,
-- credentials, vault values, or cron command bodies are included.

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
) values
  ('final-invoices', 'final-invoices', false, null, null),
  (
    'product-images',
    'product-images',
    true,
    10485760,
    array['image/jpeg','image/png','image/webp','image/gif','image/avif']
  ),
  (
    'product-media',
    'product-media',
    true,
    52428800,
    array[
      'image/jpeg','image/png','image/webp','image/gif','image/avif',
      'video/mp4','video/webm','application/pdf'
    ]
  ),
  ('proforma-invoices', 'proforma-invoices', false, null, null),
  (
    'receipts',
    'receipts',
    false,
    null,
    array['image/jpeg','image/png','image/webp','image/gif','application/pdf']
  ),
  ('trade_documents', 'trade_documents', false, null, null),
  ('trade-documents', 'trade-documents', false, null, null),
  ('whatsapp_attachments', 'whatsapp_attachments', false, null, null)
on conflict (id) do update set
  name = excluded.name,
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types,
  updated_at = now();

insert into public.storage_bucket_contracts (
  bucket_id, classification, owning_application, public_delivery,
  write_authority, path_convention, retention_notes, migration_status
) values
  ('final-invoices','private_financial','Central',false,'service_role_only','{company_id}/{invoice_id}/{filename}','Generated final invoices','active'),
  ('product-images','public_product_media','Central',true,'internal_staff','products/{product_id}/{filename}','Legacy Central hero/product images','active'),
  ('product-media','public_product_media','AI Studio',true,'internal_staff','products/{product_id}/{media_role}/{filename}','Canonical rich product media','active'),
  ('proforma-invoices','private_financial','Central',false,'service_role_only','{company_id}/{invoice_id}/{filename}','Generated proforma invoices','active'),
  ('receipts','private_financial','Central',false,'authenticated_owner_or_internal_staff','{user_id}/{receipt_id}/{filename}','Financial evidence; signed access only','active'),
  ('trade_documents','legacy_review','Legacy',false,'service_role_only','legacy/{filename}','Duplicate underscore bucket; migrate two objects after caller review','legacy'),
  ('trade-documents','private_customer_document','Customer App/Central',false,'authenticated_owner_folder','{user_id}/{document_type}/{filename}','Customer trade documents; owner and staff access','active'),
  ('whatsapp_attachments','private_internal','Central',false,'authenticated_internal_staff','threads/{thread_id}/{message_id}/{filename}','WhatsApp evidence and attachments','active')
on conflict (bucket_id) do update set
  classification = excluded.classification,
  owning_application = excluded.owning_application,
  public_delivery = excluded.public_delivery,
  write_authority = excluded.write_authority,
  path_convention = excluded.path_convention,
  retention_notes = excluded.retention_notes,
  migration_status = excluded.migration_status,
  updated_at = now();

insert into public.realtime_subscription_contracts (
  schema_name, table_name, owning_application, consumer_applications,
  enabled, row_filter_required, rls_required, event_types, notes
) values
  ('public','whatsapp_inbound_messages','Central',array['Central','AI Studio'],true,true,true,array['INSERT','UPDATE'],'Operator inbox inbound message refresh'),
  ('public','whatsapp_operator_decisions','Central',array['Central','AI Studio'],true,true,true,array['INSERT','UPDATE'],'Operator decision refresh'),
  ('public','whatsapp_sales_order_drafts','Central',array['Central','AI Studio'],true,true,true,array['INSERT','UPDATE'],'Sales-order draft refresh')
on conflict (schema_name, table_name) do update set
  owning_application = excluded.owning_application,
  consumer_applications = excluded.consumer_applications,
  enabled = excluded.enabled,
  row_filter_required = excluded.row_filter_required,
  rls_required = excluded.rls_required,
  event_types = excluded.event_types,
  notes = excluded.notes,
  updated_at = now();

insert into public.retry_policies (
  policy_key, owning_application, workload_type, max_attempts,
  base_delay_seconds, max_delay_seconds, backoff_multiplier,
  jitter_percent, dead_letter_enabled, is_active
) values
  ('notification.delivery.default','Supabase Core','notification_delivery',5,60,3600,2.000,10,true,true),
  ('whatsapp.delivery.default','Central','whatsapp_delivery',5,30,1800,2.000,15,true,true)
on conflict (policy_key) do update set
  owning_application = excluded.owning_application,
  workload_type = excluded.workload_type,
  max_attempts = excluded.max_attempts,
  base_delay_seconds = excluded.base_delay_seconds,
  max_delay_seconds = excluded.max_delay_seconds,
  backoff_multiplier = excluded.backoff_multiplier,
  jitter_percent = excluded.jitter_percent,
  dead_letter_enabled = excluded.dead_letter_enabled,
  is_active = excluded.is_active,
  updated_at = now();

insert into public.whatsapp_studio_inbox_bridge_state (id)
values (1)
on conflict (id) do nothing;

insert into public.access_permissions (
  permission_key, description, risk_level, is_active, requires_step_up
) values
  ('org.manage','Create or modify company hierarchy and memberships','sensitive',true,false),
  ('org.read','Read company, branch, contact and membership hierarchy','standard',true,false),
  ('rbac.manage','Create or modify role and permission grants','high_risk',true,true),
  ('rbac.read','Read roles, permissions and grants','standard',true,false)
on conflict (permission_key) do update set
  description = excluded.description,
  risk_level = excluded.risk_level,
  is_active = excluded.is_active,
  requires_step_up = excluded.requires_step_up,
  updated_at = now();

insert into public.role_permission_grants (
  role_key, permission_key, effect
) values
  ('admin','org.manage','allow'),
  ('admin','org.read','allow'),
  ('admin','rbac.read','allow'),
  ('operations','org.read','allow'),
  ('owner','org.manage','allow'),
  ('owner','org.read','allow'),
  ('owner','rbac.read','allow'),
  ('sales','org.read','allow'),
  ('super_admin','org.manage','allow'),
  ('super_admin','org.read','allow'),
  ('super_admin','rbac.manage','allow'),
  ('super_admin','rbac.read','allow')
on conflict (role_key, permission_key) do update set
  effect = excluded.effect;
