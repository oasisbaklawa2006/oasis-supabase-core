-- Core #407: scoped AI Studio Product Master authority for legacy SUPER_ADMIN identities.
-- Preserve public.is_admin() exactly as-is; 22 unrelated public RLS policies depend on it.
-- Intentional eligibility:
--   active users.role = 'admin' | 'super_admin' (existing product writers)
--   active users.role = 'SUPER_ADMIN' ONLY when individually listed (unrevoked) in public.product_master_authors
--     (two owner-approved holders; future SUPER_ADMIN holders are NOT authorised automatically)
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
--   remove the public.product_master_authors allowlist table (only after the function is gone)
-- Do not apply rollback without reviewing other migrations depending on this function.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- Durable individual authorisation for the legacy uppercase SUPER_ADMIN spelling.
-- A role spelling alone never grants authoring: each holder must be listed here by
-- immutable user id. Rows are added/revoked only through a reviewed migration.
CREATE TABLE IF NOT EXISTS public.product_master_authors (
  user_id uuid PRIMARY KEY REFERENCES public.users (id) ON DELETE CASCADE,
  basis text NOT NULL CHECK (btrim(basis) <> ''),
  approved_by text NOT NULL CHECK (btrim(approved_by) <> ''),
  approved_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
ALTER TABLE public.product_master_authors ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.product_master_authors FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.product_master_authors TO service_role;
COMMENT ON TABLE public.product_master_authors IS
  'Core #407: individually owner-approved legacy SUPER_ADMIN Product Master authors; read only through can_write_product_master(); no client policies by design';

-- Owner decision 2026-11-01: exactly these two active legacy SUPER_ADMIN identities (id AND email must match).
INSERT INTO public.product_master_authors (user_id, basis, approved_by)
SELECT u.id, 'Core #407 owner approval: Product Master create/edit (no hard-delete, pricing or publication)', 'owner'
FROM public.users AS u
WHERE (u.id, lower(u.email)) IN (
  ('d505bbcf-577a-4f8d-8816-2ec080b2be15'::uuid, 'admin@oasisbaklawa.com'),
  ('27b47613-8004-46c6-9fe7-6dcc6c76bb01'::uuid, 'purecocoa@live.in'))
  AND u.role = 'SUPER_ADMIN'
ON CONFLICT (user_id) DO NOTHING;

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
      AND (
        u.role IN ('admin', 'super_admin')
        OR (
          u.role = 'SUPER_ADMIN'
          AND u.deleted_at IS NULL
          AND EXISTS (
            SELECT 1 FROM public.product_master_authors AS a
            WHERE a.user_id = u.id AND a.revoked_at IS NULL
          )
        )
      )
  );
$function$;

REVOKE ALL ON FUNCTION public.can_write_product_master() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_write_product_master() TO authenticated, service_role;
COMMENT ON FUNCTION public.can_write_product_master() IS
  'Core #407: active canonical admin or super_admin plus individually approved legacy SUPER_ADMIN authors (public.product_master_authors) may author product, product_media and product_variants; no global admin elevation';

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
