-- Buyer #64 / Core #495 P0: prevent direct Data API execution of the internal
-- gateway amount-derivation helper. The helper is SECURITY DEFINER and reads
-- order/PI/credit/payment facts without checking the calling buyer's company.
--
-- Source provenance: the original 20260907141000 gateway migration revoked
-- PUBLIC, anon and service_role, but omitted authenticated. Default Supabase
-- function grants make that omission observable on a clean hosted replay.
-- Production already denies direct authenticated EXECUTE; this forward-only
-- migration is a no-op for that production grant and closes new-preview drift.
--
-- Allowed entry point remains create_payment_gateway_payable_intent_v1(), whose
-- SECURITY DEFINER implementation validates caller, company and order binding
-- before invoking this helper as its owner. Do not grant the helper directly.
--
-- Rollback (ONLY in a disposable preview, after independent approval):
--   GRANT EXECUTE ON FUNCTION public.derive_payment_gateway_canonical_amount_v1(
--     uuid, uuid, uuid, text) TO authenticated;
-- Do not use this rollback in production; it reintroduces a P0 disclosure risk.
--
-- No table writes, RLS changes, application deployment or provider calls.

REVOKE ALL ON FUNCTION
  public.derive_payment_gateway_canonical_amount_v1(uuid, uuid, uuid, text)
FROM PUBLIC, anon, authenticated, service_role;
