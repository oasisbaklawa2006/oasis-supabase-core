-- Gifting Enquiries first-deploy: restricted release-prerequisite verifier.
--
-- The production first-deploy preflight connects as oasis_drift_watch_ro, which (by design) has no table
-- privileges in public. Its read-only gate `SELECT 1 FROM public.connect_profiles WHERE profile_key =
-- 'gifting_enquiries_v1'` therefore fails with 42501 (run 45649647525), even though the profile exists.
--
-- Fix without widening table access or weakening the gate: a single-purpose SECURITY DEFINER predicate that
-- answers only "does the write-only gifting_enquiries_v1 Connect profile exist?" and returns a boolean. It reads
-- no other row, returns no profile content, takes no argument, and is executable by oasis_drift_watch_ro only.
--
-- No table grant, no RLS change, no data change. Forward-only. Rollback (owner approval only):
--   DROP FUNCTION public.gifting_enquiries_release_prerequisite_v1();

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.gifting_enquiries_release_prerequisite_v1()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.connect_profiles
    WHERE profile_key = 'gifting_enquiries_v1'
  );
$$;

REVOKE ALL ON FUNCTION public.gifting_enquiries_release_prerequisite_v1()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gifting_enquiries_release_prerequisite_v1()
  TO oasis_drift_watch_ro;

COMMENT ON FUNCTION public.gifting_enquiries_release_prerequisite_v1() IS
  'Release-preflight predicate only: true when the gifting_enquiries_v1 Connect profile exists. Executable by oasis_drift_watch_ro alone.';
