-- Core P0 (#488): enforce mandatory quote consent on Buyer CUSTOMER_APP checkout.
-- Production already exposes submit_customer_order_quoted_v1 + customer_checkout_quote_v1;
-- submit_customer_order_v1 remained directly executable by authenticated PostgREST
-- sessions and could bind a sales order without fingerprint validation.
-- Rollback: re-GRANT EXECUTE on submit_customer_order_v1(text,date) TO authenticated
-- (Buyer must remain on quoted submit before rollback in production).

REVOKE ALL ON FUNCTION public.submit_customer_order_v1(text, date)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.submit_customer_order_v1(text, date) TO service_role;

COMMENT ON FUNCTION public.submit_customer_order_v1(text, date) IS
  'Canonical CUSTOMER_APP checkout writer. Callable by service_role and privileged owner-mediated quote wrappers only; authenticated buyers must use submit_customer_order_quoted_v1.';
