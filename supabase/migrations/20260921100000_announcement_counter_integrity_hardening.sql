-- Task 5 CERT-SEC-002: harden announcement analytics integrity.
-- Preserve the legacy two-argument RPC shape for authenticated clients while
-- making increments server-idempotent per authenticated actor/announcement/counter.
-- Anonymous callers are deliberately denied: unauthenticated replayable counters
-- are not authoritative analytics.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE IF NOT EXISTS public.announcement_counter_receipts (
  announcement_id uuid NOT NULL
    REFERENCES public.premium_announcements(id) ON DELETE CASCADE,
  actor_id uuid NOT NULL
    REFERENCES auth.users(id) ON DELETE CASCADE,
  counter_name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT announcement_counter_receipts_pkey
    PRIMARY KEY (announcement_id, actor_id, counter_name),
  CONSTRAINT announcement_counter_receipts_counter_name_check
    CHECK (counter_name IN ('view', 'skip', 'completion'))
);

ALTER TABLE public.announcement_counter_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.announcement_counter_receipts
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.announcement_counter_receipts TO service_role;

COMMENT ON TABLE public.announcement_counter_receipts IS
  'Server-owned idempotency receipts for premium announcement counters. One '
  'count per authenticated actor, announcement and counter type; direct '
  'browser access is denied.';

CREATE OR REPLACE FUNCTION public.increment_announcement_counter(
  ann_id uuid,
  counter_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_actor_id uuid := auth.uid();
  v_counter_name text := lower(btrim(coalesce(counter_name, '')));
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'ANNOUNCEMENT_COUNTER_AUTH_REQUIRED'
      USING ERRCODE = '42501';
  END IF;

  IF v_counter_name NOT IN ('view', 'skip', 'completion') THEN
    RAISE EXCEPTION 'ANNOUNCEMENT_COUNTER_INVALID'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.announcement_counter_receipts (
    announcement_id,
    actor_id,
    counter_name
  )
  VALUES (
    ann_id,
    v_actor_id,
    v_counter_name
  )
  ON CONFLICT ON CONSTRAINT announcement_counter_receipts_pkey DO NOTHING;

  -- FOUND is false when the receipt already existed. A retry/replay is then a
  -- no-op rather than another analytics mutation.
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_counter_name = 'view' THEN
    UPDATE public.premium_announcements
       SET view_count = view_count + 1
     WHERE id = ann_id;
  ELSIF v_counter_name = 'skip' THEN
    UPDATE public.premium_announcements
       SET skip_count = skip_count + 1
     WHERE id = ann_id;
  ELSE
    UPDATE public.premium_announcements
       SET completion_count = completion_count + 1
     WHERE id = ann_id;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.increment_announcement_counter(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.increment_announcement_counter(uuid, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.increment_announcement_counter(uuid, text) IS
  'Authenticated, idempotent premium-announcement analytics increment. '
  'Anonymous replay is denied; duplicate actor/announcement/counter calls are no-ops.';
