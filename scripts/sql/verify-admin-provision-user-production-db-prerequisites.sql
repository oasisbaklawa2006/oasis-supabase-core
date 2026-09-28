-- Read-only production database prerequisites for admin-provision-user first deploy.
-- Must not mutate schema, data, secrets, or auth identities.

\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM supabase_migrations.schema_migrations
    WHERE version = '20260819110000'
  ) THEN
    RAISE EXCEPTION 'ADMIN_PROVISION_DB_PREREQ: migration 20260819110000 not applied';
  END IF;

  IF to_regprocedure('public.can_grant_staff_role(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_PROVISION_DB_PREREQ: public.can_grant_staff_role missing';
  END IF;

  IF to_regprocedure(
    'public.grant_staff_role(uuid,text,text,text,uuid,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'ADMIN_PROVISION_DB_PREREQ: public.grant_staff_role missing';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.grant_staff_role(uuid,text,text,text,uuid,text,text)',
    'execute'
  ) THEN
    RAISE EXCEPTION 'ADMIN_PROVISION_DB_PREREQ: anon may execute grant_staff_role';
  END IF;

  IF has_function_privilege(
    'authenticated',
    'public.grant_staff_role(uuid,text,text,text,uuid,text,text)',
    'execute'
  ) THEN
    RAISE EXCEPTION 'ADMIN_PROVISION_DB_PREREQ: authenticated may execute grant_staff_role';
  END IF;

  IF NOT has_function_privilege(
    'service_role',
    'public.grant_staff_role(uuid,text,text,text,uuid,text,text)',
    'execute'
  ) THEN
    RAISE EXCEPTION 'ADMIN_PROVISION_DB_PREREQ: service_role cannot execute grant_staff_role';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.staff_provisionable_roles
    WHERE role_key = 'prod_arabic_sweets'
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'ADMIN_PROVISION_DB_PREREQ: prod_arabic_sweets is not an active provisionable role';
  END IF;
END $$;

SELECT 'ADMIN_PROVISION_DB_PREREQ_OK' AS status;
