-- Read-only protected-state census; never return raw records or credentials.
BEGIN READ ONLY;
SELECT jsonb_build_object(
  'auth.users', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM auth.users t),
  'auth.identities', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM auth.identities t),
  'auth.sessions', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM auth.sessions t),
  'auth.refresh_tokens', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM auth.refresh_tokens t),
  'auth.audit_log_entries', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM auth.audit_log_entries t),
  'public.users', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.users t),
  'public.profiles', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.profiles t),
  'public.companies', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.companies t),
  'public.b2b_applications', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.b2b_applications t),
  'public.customer_order_drafts', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.customer_order_drafts t),
  'public.customer_order_draft_lines', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.customer_order_draft_lines t),
  'public.customer_order_draft_audit_log', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.customer_order_draft_audit_log t),
  'public.products', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.products t),
  'public.product_pricing_rules', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.product_pricing_rules t),
  'public.product_moq_rules', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.product_moq_rules t),
  'public.orders', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM public.orders t),
  'storage.objects', (SELECT jsonb_build_object('count', count(*), 'sha256', encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]'), 'UTF8')), 'hex')) FROM storage.objects t)
)::text;
COMMIT;
