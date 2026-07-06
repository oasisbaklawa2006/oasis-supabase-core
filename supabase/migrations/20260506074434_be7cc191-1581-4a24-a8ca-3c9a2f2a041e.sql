CREATE OR REPLACE FUNCTION public.get_current_user_roles()
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid uuid := auth.uid();
  roles_array text[] := ARRAY[]::text[];
BEGIN
  IF uid IS NULL THEN
    RETURN ARRAY[]::text[];
  END IF;

  PERFORM public.bootstrap_current_user();

  SELECT COALESCE(array_agg(ur.role::text ORDER BY ur.role::text), ARRAY[]::text[])
    INTO roles_array
  FROM public.user_roles ur
  WHERE ur.user_id = uid;

  RETURN roles_array;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_current_user_roles() TO authenticated;