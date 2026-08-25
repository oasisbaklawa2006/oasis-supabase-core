-- Restore the read privileges required by the security-invoker
-- b2b_order_availability view.
--
-- The original Phase 2 contract created role-scoped SELECT policies for
-- authenticated internal staff on b2b_inventory_stores and
-- b2b_inventory_item_profiles, but never granted SELECT on those relations
-- (or on the view itself). PostgreSQL evaluates both table privileges and RLS;
-- without the grants, the policies are unreachable and Central's RGS demand
-- screen fails before rendering.
--
-- Keep the view security_invoker=true so the existing internal-staff RLS
-- policies remain authoritative. Do not grant anonymous access.

GRANT SELECT ON TABLE public.b2b_inventory_stores TO authenticated;
GRANT SELECT ON TABLE public.b2b_inventory_item_profiles TO authenticated;
GRANT SELECT ON TABLE public.b2b_order_availability TO authenticated;

REVOKE ALL ON TABLE public.b2b_inventory_stores FROM anon;
REVOKE ALL ON TABLE public.b2b_inventory_item_profiles FROM anon;
REVOKE ALL ON TABLE public.b2b_order_availability FROM anon;
