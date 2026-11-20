-- GFT-100 / Central #677: internal retail helpers are not edge RPC entry points.
-- Supabase's function defaults can grant service_role EXECUTE independently of
-- PUBLIC. Keep these helpers callable only through their owning definer routines.
-- Forward correction of 20261119100000; no migration history or data changes.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

REVOKE ALL ON FUNCTION public.retail_setting_approved_v1(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.retail_session_resolve_v1(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.retail_price_resolve_v1(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.retail_tax_breakdown_v1(numeric, numeric, boolean)
  FROM PUBLIC, anon, authenticated, service_role;
