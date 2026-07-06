-- Grant EXECUTE on helper / RLS support functions to authenticated users.
-- These are SECURITY DEFINER where needed and have search_path = public set.

GRANT EXECUTE ON FUNCTION public.is_team_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_current_user_roles() TO authenticated;
GRANT EXECUTE ON FUNCTION public.bootstrap_current_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_oasis_sku(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_alias(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.search_products_with_aliases(text) TO authenticated, anon;