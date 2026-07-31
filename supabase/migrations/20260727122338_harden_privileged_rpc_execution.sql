-- Issue #16, tranche C: restrict privileged RPC execution to verified callers.
-- RLS helper functions and the two intentional anonymous application contracts
-- remain unchanged. Ingestion and unguarded administrative routines are service-only.

revoke execute on function public.approve_catalogue_alias_draft(uuid) from public, anon;
revoke execute on function public.approve_catalogue_bom_draft(uuid) from public, anon;
revoke execute on function public.approve_catalogue_draft_internal(text,uuid) from public, anon;
revoke execute on function public.approve_catalogue_media_submission(uuid) from public, anon;
revoke execute on function public.approve_catalogue_moq_draft(uuid) from public, anon;
revoke execute on function public.approve_catalogue_pricing_draft(uuid) from public, anon;
revoke execute on function public.approve_catalogue_product_draft(uuid) from public, anon;
revoke execute on function public.approve_catalogue_tag_draft(uuid) from public, anon;
revoke execute on function public.approve_sales_order_draft_for_so_atomic(uuid,text,uuid,text,text,jsonb) from public, anon;
revoke execute on function public.create_sales_order_draft_atomic(jsonb,jsonb,uuid,text,jsonb) from public, anon;
revoke execute on function public.create_whatsapp_sales_order_draft_from_operator(uuid,text,text,uuid,text,text,numeric) from public, anon;
revoke execute on function public.generate_oasis_sku(text,text,text,text) from public, anon;
revoke execute on function public.get_current_user_roles() from public, anon;
revoke execute on function public.get_my_role_keys() from public, anon;
revoke execute on function public.log_cart_failure(uuid,text,text,jsonb) from public, anon;
revoke execute on function public.record_whatsapp_operator_decision(uuid,text,text,text,text) from public, anon;
revoke execute on function public.reject_catalogue_alias_draft(uuid,text) from public, anon;
revoke execute on function public.reject_catalogue_bom_draft(uuid,text) from public, anon;
revoke execute on function public.reject_catalogue_draft_internal(text,uuid,text) from public, anon;
revoke execute on function public.reject_catalogue_media_submission(uuid,text) from public, anon;
revoke execute on function public.reject_catalogue_moq_draft(uuid,text) from public, anon;
revoke execute on function public.reject_catalogue_pricing_draft(uuid,text) from public, anon;
revoke execute on function public.reject_catalogue_product_draft(uuid,text) from public, anon;
revoke execute on function public.reject_catalogue_tag_draft(uuid,text) from public, anon;
revoke execute on function public.reject_sales_order_draft_atomic(uuid,uuid,text,text,text,jsonb) from public, anon;
revoke execute on function public.run_customer_import_validation(uuid) from public, anon;
revoke execute on function public.storage_object_path_matches_buyer_owned_order(text) from public, anon;
revoke execute on function public.submit_sales_order_draft_for_review_atomic(uuid,text,jsonb,integer,jsonb,jsonb,uuid,text,jsonb) from public, anon;
revoke execute on function public.transition_sales_order_draft_status(uuid,text,text,text,uuid,text,text,text,uuid,text,jsonb) from public, anon;
revoke execute on function public.update_sales_order_draft_operator_final(uuid,text,jsonb,integer,jsonb,jsonb,uuid,text,jsonb) from public, anon;

revoke execute on function public.ingest_whatsapp_inbound_message(text,text,text,text,text,timestamptz,jsonb,text,jsonb) from public, anon, authenticated;
revoke execute on function public.restore_order_financials(uuid) from public, anon, authenticated;
revoke execute on function public.run_month_end_credit_lock() from public, anon, authenticated;

-- New routines owned by postgres must opt in to browser-role execution explicitly,
-- regardless of which schema contains them.
alter default privileges for role postgres
  revoke execute on functions from public, anon, authenticated;
