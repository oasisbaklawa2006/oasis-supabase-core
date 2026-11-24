-- Website enquiry leads: single backend authority in Oasis Core.
--
-- Gifting's leadsRepository() persists website leads directly to Core Production. There is no
-- separate Gifting production Supabase project. This migration is additive: it creates
-- public.website_leads and one retention helper. No existing object is altered.
--
-- Access model: RLS is enabled with NO policies, and anon/authenticated have no privileges on the
-- table. Only service_role (server-side Gifting code, using its own service key) can read or write.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE public.website_leads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('newsletter', 'contact', 'corporate', 'wedding', 'rewards', 'partnership')),
  dedupe_key text NOT NULL,
  email text,
  phone text,
  full_name text,
  company text,
  message text,
  source text NOT NULL,
  attribution jsonb NOT NULL DEFAULT '{}'::jsonb,
  marketing_consent boolean NOT NULL DEFAULT false,
  consent_at timestamptz,
  submission_count integer NOT NULL DEFAULT 1,
  sync_state text NOT NULL DEFAULT 'pending_sync' CHECK (sync_state IN ('pending_sync', 'synced', 'failed')),
  sync_detail text,
  synced_at timestamptz,
  last_submitted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT website_leads_contact_present CHECK (email IS NOT NULL OR phone IS NOT NULL),
  CONSTRAINT website_leads_dedupe_key_unique UNIQUE (dedupe_key)
);

COMMENT ON TABLE public.website_leads IS
  'Website enquiry leads written by the Gifting server with service_role only. Not readable by anon or authenticated.';

ALTER TABLE public.website_leads ENABLE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES ON TABLE public.website_leads FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.website_leads TO service_role;

CREATE OR REPLACE FUNCTION public.website_leads_touch_updated_at_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.website_leads_touch_updated_at_v1() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER website_leads_touch_updated_at
  BEFORE UPDATE ON public.website_leads
  FOR EACH ROW
  EXECUTE FUNCTION public.website_leads_touch_updated_at_v1();

-- Retention helper. Deletes only leads already delivered to Core's enquiry queue (sync_state = 'synced')
-- and older than the caller's retention window. Leads that are pending_sync or failed are never purged
-- automatically, so an undelivered enquiry cannot be lost. Minimum retention is 30 days. There is no
-- scheduler; the caller decides when to run it.
CREATE OR REPLACE FUNCTION public.purge_synced_website_leads_v1(p_retain_days integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  removed integer;
BEGIN
  IF p_retain_days IS NULL OR p_retain_days < 30 THEN
    RAISE EXCEPTION 'WEBSITE_LEADS_RETENTION_TOO_SHORT' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM public.website_leads
   WHERE sync_state = 'synced'
     AND synced_at < now() - make_interval(days => p_retain_days);
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN removed;
END;
$$;

REVOKE ALL ON FUNCTION public.purge_synced_website_leads_v1(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_synced_website_leads_v1(integer) TO service_role;
