-- GFT-100 / Central #677: governed staff read + triage path for Gifting website enquiries.
--
-- Stacked on 20261118210000_gifting_enquiry_receiver_v1.sql (public.gifting_enquiries, service_role only).
-- Central owns the staff queue UI; Core owns the data and the authorization. Staff never read the table
-- directly: they call two SECURITY DEFINER RPCs that require an active admin/super_admin
-- (public.is_admin(), the narrowest existing role rule).
--
-- PERMISSION DECISION PENDING (not invented here): whether sales_manager or other roles may read
-- D2C enquiry personal data. Widening it is a one-line change to gifting_enquiry_queue_authorized() that
-- needs explicit owner approval; see docs/programme/GIFTING_ENQUIRY_STAFF_QUEUE.md.
-- Retention/deletion of enquiry personal data is likewise an open policy decision.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

ALTER TABLE public.gifting_enquiries
  ADD COLUMN IF NOT EXISTS status_changed_by uuid,
  ADD COLUMN IF NOT EXISTS status_changed_at timestamptz;

CREATE OR REPLACE FUNCTION public.gifting_enquiry_queue_authorized()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT coalesce(public.is_admin(), false);
$$;

COMMENT ON FUNCTION public.gifting_enquiry_queue_authorized() IS
  'Single authorization rule for the Gifting enquiry staff queue (active admin/super_admin). Widening roles requires explicit approval.';

CREATE OR REPLACE FUNCTION public.gifting_enquiry_queue_list_v1(
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  kind text,
  name text,
  company text,
  email text,
  phone text,
  message text,
  source text,
  marketing_consent boolean,
  status text,
  receipt_count integer,
  environment text,
  first_received_at timestamptz,
  last_received_at timestamptz,
  status_changed_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT public.gifting_enquiry_queue_authorized() THEN
    RAISE EXCEPTION 'GIFTING_QUEUE_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 OR p_offset > 100000 THEN
    RAISE EXCEPTION 'GIFTING_QUEUE_INVALID' USING ERRCODE = '22023';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('received', 'triaged', 'closed', 'spam') THEN
    RAISE EXCEPTION 'GIFTING_QUEUE_INVALID' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT e.id, e.kind, e.name, e.company, e.email, e.phone, e.message, e.source,
         e.marketing_consent, e.status, e.receipt_count, e.environment,
         e.first_received_at, e.last_received_at, e.status_changed_at
    FROM public.gifting_enquiries e
   WHERE p_status IS NULL OR e.status = p_status
   ORDER BY e.first_received_at DESC, e.id
   LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.gifting_enquiry_queue_set_status_v1(
  p_enquiry_id uuid,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.gifting_enquiries%ROWTYPE;
BEGIN
  IF NOT public.gifting_enquiry_queue_authorized() THEN
    RAISE EXCEPTION 'GIFTING_QUEUE_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF p_enquiry_id IS NULL OR p_status IS NULL OR p_status NOT IN ('received', 'triaged', 'closed', 'spam') THEN
    RAISE EXCEPTION 'GIFTING_QUEUE_INVALID' USING ERRCODE = '22023';
  END IF;

  UPDATE public.gifting_enquiries
     SET status = p_status,
         status_changed_by = auth.uid(),
         status_changed_at = now()
   WHERE id = p_enquiry_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'GIFTING_QUEUE_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('id', v_row.id, 'status', v_row.status, 'statusChangedAt', v_row.status_changed_at);
END;
$$;

REVOKE ALL ON FUNCTION public.gifting_enquiry_queue_authorized() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gifting_enquiry_queue_list_v1(text, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gifting_enquiry_queue_set_status_v1(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gifting_enquiry_queue_authorized() TO service_role;
GRANT EXECUTE ON FUNCTION public.gifting_enquiry_queue_list_v1(text, integer, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gifting_enquiry_queue_set_status_v1(uuid, text) TO authenticated, service_role;
