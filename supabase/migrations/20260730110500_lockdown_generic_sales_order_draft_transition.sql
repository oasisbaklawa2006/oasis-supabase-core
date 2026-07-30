-- Lock down the legacy generic draft-transition RPC.
-- Browser callers must use the specialized guarded RPCs instead:
--   update_sales_order_draft_operator_final
--   submit_sales_order_draft_for_review_atomic
--   approve_sales_order_draft_for_so_atomic
--   reject_sales_order_draft_atomic

revoke all on function public.transition_sales_order_draft_status(
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  jsonb
) from public, anon, authenticated;

grant execute on function public.transition_sales_order_draft_status(
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  jsonb
) to service_role;

comment on function public.transition_sales_order_draft_status(
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  jsonb
) is
  'Deprecated internal-only transition primitive. Browser roles must use the specialized guarded sales-order-draft RPCs.';
