-- Oasis-owned least-privilege PostgreSQL role for Production Migration Drift Watch.
-- Replaces dependence on Supabase's reserved supabase_read_only_user, which cannot
-- be hardened (rolbypassrls=true is platform-managed and immutable).
-- The role remains NOLOGIN until the owner separately enables LOGIN and rotates the
-- supabase-production-readonly GitHub environment secret after governed deployment.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'oasis_drift_watch_ro') THEN
    CREATE ROLE oasis_drift_watch_ro
      NOLOGIN
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOREPLICATION
      NOBYPASSRLS
      NOINHERIT;
  END IF;

  EXECUTE format(
    'GRANT CONNECT ON DATABASE %I TO oasis_drift_watch_ro',
    current_database()
  );
  EXECUTE format(
    'REVOKE ALL ON SCHEMA %I FROM oasis_drift_watch_ro',
    'supabase_migrations'
  );
  EXECUTE format(
    'GRANT USAGE ON SCHEMA %I TO oasis_drift_watch_ro',
    'supabase_migrations'
  );
  EXECUTE format(
    'REVOKE ALL ON TABLE %I.%I FROM oasis_drift_watch_ro',
    'supabase_migrations',
    'schema_migrations'
  );
  EXECUTE format(
    'GRANT SELECT ON TABLE %I.%I TO oasis_drift_watch_ro',
    'supabase_migrations',
    'schema_migrations'
  );
END
$$;

ALTER ROLE oasis_drift_watch_ro SET default_transaction_read_only = on;
ALTER ROLE oasis_drift_watch_ro SET search_path = pg_catalog, storage, supabase_migrations;

REVOKE ALL ON SCHEMA public FROM oasis_drift_watch_ro;
REVOKE USAGE ON SCHEMA public FROM oasis_drift_watch_ro;
REVOKE CREATE ON SCHEMA public FROM oasis_drift_watch_ro;
REVOKE ALL ON SCHEMA auth FROM oasis_drift_watch_ro;
REVOKE ALL ON SCHEMA storage FROM oasis_drift_watch_ro;

GRANT USAGE ON SCHEMA extensions TO oasis_drift_watch_ro;
GRANT USAGE ON SCHEMA storage TO oasis_drift_watch_ro;

REVOKE ALL ON TABLE storage.buckets FROM oasis_drift_watch_ro;
GRANT SELECT ON TABLE storage.buckets TO oasis_drift_watch_ro;

REVOKE ALL ON TABLE storage.objects FROM oasis_drift_watch_ro;

DROP POLICY IF EXISTS oasis_drift_watch_ro_select_buckets ON storage.buckets;
CREATE POLICY oasis_drift_watch_ro_select_buckets
  ON storage.buckets
  FOR SELECT
  TO oasis_drift_watch_ro
  USING (true);

-- Allow pgTAP SET ROLE and local replay PGOPTIONS=-c role=... impersonation.
-- oasis_drift_watch_ro retains zero parent-role memberships.
GRANT oasis_drift_watch_ro TO postgres;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_namespace n
    JOIN pg_roles r ON r.rolname = 'oasis_drift_watch_ro'
    JOIN LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) acl
      ON acl.grantee = r.oid
    WHERE n.nspname = 'public'
      AND acl.privilege_type IN ('USAGE', 'CREATE')
  ) THEN
    RAISE EXCEPTION
      'oasis_drift_watch_ro must not hold direct public schema USAGE/CREATE privileges';
  END IF;
END
$$;
