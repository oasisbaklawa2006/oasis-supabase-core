-- Post-baseline privilege hardening for customer-facing contracts.
-- The canonical production baseline materializes these objects; this migration
-- narrows browser-role privileges to the approved customer contract boundary.

revoke all on function public.buyer_product_prices_v1() from public, anon;
grant execute on function public.buyer_product_prices_v1() to authenticated, service_role;

revoke all on function public.customer_order_status_v1() from public, anon;
grant execute on function public.customer_order_status_v1() to authenticated, service_role;

revoke all on function public.customer_order_items_v1() from public, anon;
grant execute on function public.customer_order_items_v1() to authenticated, service_role;

revoke all on function public.customer_support_tickets_v1() from public, anon;
grant execute on function public.customer_support_tickets_v1() to authenticated, service_role;

revoke all on function public.submit_customer_support_ticket_v1(uuid,text,text,text,integer) from public, anon;
grant execute on function public.submit_customer_support_ticket_v1(uuid,text,text,text,integer) to authenticated, service_role;

revoke all on table public.support_tickets from anon, authenticated;
grant select, insert, update, delete on table public.support_tickets to authenticated;

revoke all on table public.tickets from anon, authenticated;

comment on function public.buyer_product_prices_v1() is
  'Authenticated buyer price and MOQ contract. Anonymous and PUBLIC execution revoked by 20260730170000.';
comment on function public.customer_order_status_v1() is
  'Authenticated customer order-status contract. Anonymous and PUBLIC execution revoked by 20260730170000.';
comment on function public.customer_order_items_v1() is
  'Authenticated customer order-item contract. Anonymous and PUBLIC execution revoked by 20260730170000.';
comment on function public.customer_support_tickets_v1() is
  'Authenticated company-scoped support-ticket contract. Anonymous and PUBLIC execution revoked by 20260730170000.';
comment on function public.submit_customer_support_ticket_v1(uuid,text,text,text,integer) is
  'Authenticated company-scoped support-ticket submission contract. Anonymous and PUBLIC execution revoked by 20260730170000.';
