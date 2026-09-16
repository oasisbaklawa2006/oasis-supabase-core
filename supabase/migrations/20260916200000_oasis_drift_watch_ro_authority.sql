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
END
$$;

ALTER ROLE oasis_drift_watch_ro
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION
  NOBYPASSRLS
  NOINHERIT
  NOLOGIN;

ALTER ROLE oasis_drift_watch_ro SET default_transaction_read_only = on;

EXECUTE format(
  'GRANT CONNECT ON DATABASE %I TO oasis_drift_watch_ro',
  current_database()
);

REVOKE ALL ON SCHEMA public FROM oasis_drift_watch_ro;
REVOKE ALL ON SCHEMA auth FROM oasis_drift_watch_ro;
REVOKE ALL ON SCHEMA storage FROM oasis_drift_watch_ro;
REVOKE ALL ON SCHEMA supabase_migrations FROM oasis_drift_watch_ro;

GRANT USAGE ON SCHEMA storage TO oasis_drift_watch_ro;
GRANT USAGE ON SCHEMA supabase_migrations TO oasis_drift_watch_ro;

REVOKE ALL ON TABLE storage.buckets FROM oasis_drift_watch_ro;
GRANT SELECT ON TABLE storage.buckets TO oasis_drift_watch_ro;

REVOKE ALL ON TABLE storage.objects FROM oasis_drift_watch_ro;

REVOKE ALL ON TABLE supabase_migrations.schema_migrations FROM oasis_drift_watch_ro;
GRANT SELECT ON TABLE supabase_migrations.schema_migrations TO oasis_drift_watch_ro;

DROP POLICY IF EXISTS oasis_drift_watch_ro_select_buckets ON storage.buckets;
CREATE POLICY oasis_drift_watch_ro_select_buckets
  ON storage.buckets
  FOR SELECT
  TO oasis_drift_watch_ro
  USING (true);
