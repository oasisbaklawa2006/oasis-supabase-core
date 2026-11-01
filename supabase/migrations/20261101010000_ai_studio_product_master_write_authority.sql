-- Core #407: scoped AI Studio Product Master authority for legacy SUPER_ADMIN identities.
-- Preserve public.is_admin() exactly as-is; 22 unrelated public RLS policies depend on it.
-- Intentional eligibility:
--   active users.role = 'admin' | 'super_admin' (existing product writers)
--   active users.role = 'SUPER_ADMIN' (two currently approved legacy holders)
-- Explicitly excludes 'ADMIN', owner, product_manager and catalogue_contributor.
-- Future product_manager authoring requires individually governed assignment in a
-- separate approved migration; no blanket product_manager access is granted here.
-- Product hard deletion remains on public.is_admin() (governed lifecycle unavailable).
-- Governed publication, draft approval, commercial pricing and Central sync are unchanged.
--
-- ROLLBACK (protected migration only):
--   ALTER the eight changed policies below to use public.is_admin() again;
--   REVOKE EXECUTE on public.can_write_product_master() from authenticated,service_role;
--   DROP FUNCTION public.can_write_product_master();
-- Do not apply rollback without reviewing other migrations depending on this function.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.can_write_product_master()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.users AS u
    WHERE u.id = auth.uid()
      AND u.is_active IS TRUE
      AND u.role IN ('admin', 'super_admin', 'SUPER_ADMIN')
  );
$function$;

REVOKE ALL ON FUNCTION public.can_write_product_master() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_write_product_master() TO authenticated, service_role;
COMMENT ON FUNCTION public.can_write_product_master() IS
  'Core #407: active canonical admin or super_admin plus legacy uppercase SUPER_ADMIN may author product, product_media and product_variants; no global admin elevation';

-- Existing policy identities, commands, roles, and SELECT coverage stay unchanged.
-- Only eight product/media/variant RLS mutation predicates change.
-- The products DELETE policy deliberately remains on public.is_admin().
ALTER POLICY "Admins insert products"
  ON public.products
  WITH CHECK (public.can_write_product_master());

ALTER POLICY "Admins update products"
  ON public.products
  USING (public.can_write_product_master())
  WITH CHECK (public.can_write_product_master());

ALTER POLICY "Admins insert product media"
  ON public.product_media
  WITH CHECK (public.can_write_product_master());

ALTER POLICY "Admins update product media"
  ON public.product_media
  USING (public.can_write_product_master())
  WITH CHECK (public.can_write_product_master());

ALTER POLICY "Admins delete product media"
  ON public.product_media
  USING (public.can_write_product_master());

ALTER POLICY "Admins insert product variants"
  ON public.product_variants
  WITH CHECK (public.can_write_product_master());

ALTER POLICY "Admins update product variants"
  ON public.product_variants
  USING (public.can_write_product_master())
  WITH CHECK (public.can_write_product_master());

ALTER POLICY "Admins delete product variants"
  ON public.product_variants
  USING (public.can_write_product_master());
