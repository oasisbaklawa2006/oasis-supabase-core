-- Issue #16, tranches B/D: close direct trigger-function execution and
-- make every advisor-reported function resolve names through a deterministic
-- search path. Trigger invocation does not require callers to hold EXECUTE.

revoke execute on function public.activate_company_on_application_approval() from public, anon, authenticated;
revoke execute on function public.block_orders_when_frozen() from public, anon, authenticated;
revoke execute on function public.dispatch_completion_evidence_immutable() from public, anon, authenticated;
revoke execute on function public.dispatch_readiness_evidence_immutable() from public, anon, authenticated;
revoke execute on function public.dispatch_release_lineage_immutable() from public, anon, authenticated;
revoke execute on function public.enforce_sales_order_draft_immutable_fields() from public, anon, authenticated;
revoke execute on function public.finance_review_evidence_immutable() from public, anon, authenticated;
revoke execute on function public.guard_companies_is_frozen() from public, anon, authenticated;
revoke execute on function public.guard_is_frozen_changes() from public, anon, authenticated;
revoke execute on function public.handle_credit_payment() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.link_buyer_on_application_approval() from public, anon, authenticated;
revoke execute on function public.notify_admin_new_b2b_application() from public, anon, authenticated;
revoke execute on function public.prevent_profile_privilege_escalation() from public, anon, authenticated;
revoke execute on function public.support_ticket_set_customer_context() from public, anon, authenticated;
revoke execute on function public.update_outstanding_on_order() from public, anon, authenticated;

alter function public.get_product_price(uuid, text)
  set search_path = pg_catalog, public, auth;
alter function public.get_product_price_usd(uuid)
  set search_path = pg_catalog, public, auth;
alter function public.resolve_order_qty_to_kg(uuid, numeric, text)
  set search_path = pg_catalog, public, auth;
alter function public.dispatch_readiness_evidence_immutable()
  set search_path = pg_catalog, public, auth;
alter function public.finance_review_evidence_immutable()
  set search_path = pg_catalog, public, auth;
alter function public.dispatch_completion_evidence_immutable()
  set search_path = pg_catalog, public, auth;
alter function public.dispatch_release_lineage_immutable()
  set search_path = pg_catalog, public, auth;
alter function public.catalogue_slugify_tag_part(text)
  set search_path = pg_catalog, public, auth;
alter function public.customer_import_normalize_gst(text)
  set search_path = pg_catalog, public, auth;
alter function public.customer_import_normalize_phone_last10(text)
  set search_path = pg_catalog, public, auth;
alter function public.customer_import_normalize_payment_terms(text)
  set search_path = pg_catalog, public, auth;
alter function public.enforce_sales_order_draft_immutable_fields()
  set search_path = pg_catalog, public, auth;
alter function public.customer_import_set_updated_at()
  set search_path = pg_catalog, public, auth;
alter function public.validate_sales_order_draft_readiness(jsonb)
  set search_path = pg_catalog, public, auth;
