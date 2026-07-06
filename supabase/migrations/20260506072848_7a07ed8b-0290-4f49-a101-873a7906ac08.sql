
CREATE OR REPLACE FUNCTION public.bootstrap_current_user()
RETURNS SETOF public.user_roles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid uuid := auth.uid();
  uemail text;
  has_profile boolean;
  has_any_role boolean;
  owner_exists boolean;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT email INTO uemail FROM auth.users WHERE id = uid;

  SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id = uid) INTO has_profile;
  IF NOT has_profile THEN
    INSERT INTO public.profiles (id, email, full_name)
    VALUES (uid, uemail, COALESCE(uemail, 'User'));
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.user_roles WHERE user_id = uid) INTO has_any_role;
  IF NOT has_any_role THEN
    SELECT EXISTS(SELECT 1 FROM public.user_roles WHERE role = 'owner') INTO owner_exists;
    IF NOT owner_exists THEN
      INSERT INTO public.user_roles (user_id, role) VALUES (uid, 'owner');
    ELSE
      INSERT INTO public.user_roles (user_id, role) VALUES (uid, 'sales');
    END IF;
  END IF;

  RETURN QUERY SELECT * FROM public.user_roles WHERE user_id = uid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.bootstrap_current_user() TO authenticated;
