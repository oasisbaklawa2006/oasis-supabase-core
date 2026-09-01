-- APP-E2E general customer query resolution.
--
-- General enquiries remain orderless and separate from support_tickets/CRM complaint
-- authority. This migration adds the minimum governed internal lifecycle required
-- to ensure every captured enquiry can be acknowledged, resolved and closed.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

ALTER TABLE public.customer_general_queries
  ADD COLUMN IF NOT EXISTS customer_response text,
  ADD COLUMN IF NOT EXISTS responded_at timestamptz,
  ADD COLUMN IF NOT EXISTS responded_by uuid REFERENCES auth.users(id);

CREATE TABLE IF NOT EXISTS public.customer_general_query_idempotency (
  idempotency_key text PRIMARY KEY,
  query_id uuid NOT NULL REFERENCES public.customer_general_queries(id),
  operation text NOT NULL CHECK(operation='STATUS_CHANGE'),
  request_fingerprint text NOT NULL,
  response jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.customer_general_query_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_general_query_idempotency
  FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.manage_customer_general_query_v1(
  p_query_id uuid,
  p_target_status text,
  p_customer_response text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(
  query_id uuid,
  status text,
  customer_response text,
  already_applied boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
#variable_conflict use_column
DECLARE
  v_actor uuid:=coalesce(p_actor_id,auth.uid());
  v_target text:=upper(btrim(coalesce(p_target_status,'')));
  v_response text:=nullif(btrim(coalesce(p_customer_response,'')),'');
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_query public.customer_general_queries%rowtype;
  v_existing public.customer_general_query_idempotency%rowtype;
  v_fingerprint text;
  v_payload jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR v_actor IS DISTINCT FROM auth.uid()
     OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'GENERAL_QUERY_INTERNAL_ACTOR_REQUIRED' USING ERRCODE='42501';
  END IF;

  IF p_query_id IS NULL
     OR v_target NOT IN ('ACKNOWLEDGED','RESOLVED','CLOSED')
     OR v_key=''
     OR length(v_key)>200 THEN
    RAISE EXCEPTION 'GENERAL_QUERY_MANAGEMENT_INPUT_INVALID' USING ERRCODE='22023';
  END IF;
  IF v_target IN ('RESOLVED','CLOSED') AND v_response IS NULL THEN
    RAISE EXCEPTION 'GENERAL_QUERY_CUSTOMER_RESPONSE_REQUIRED' USING ERRCODE='22023';
  END IF;
  IF v_response IS NOT NULL AND length(v_response)>4000 THEN
    RAISE EXCEPTION 'GENERAL_QUERY_CUSTOMER_RESPONSE_TOO_LONG' USING ERRCODE='22023';
  END IF;

  v_fingerprint:=md5(concat_ws('|',
    'STATUS_CHANGE',p_query_id::text,v_target,coalesce(v_response,''),v_actor::text
  ));
  PERFORM pg_advisory_xact_lock(hashtextextended('customer-general-query-manage:'||p_query_id::text,0));

  SELECT * INTO v_existing
  FROM public.customer_general_query_idempotency
  WHERE idempotency_key=v_key;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor
       OR v_existing.query_id IS DISTINCT FROM p_query_id
       OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'GENERAL_QUERY_MANAGEMENT_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT
      v_existing.query_id,
      v_existing.response->>'status',
      v_existing.response->>'customer_response',
      true;
    RETURN;
  END IF;

  SELECT * INTO v_query
  FROM public.customer_general_queries
  WHERE id=p_query_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GENERAL_QUERY_NOT_FOUND' USING ERRCODE='P0002';
  END IF;

  IF NOT (
    (v_query.status='SUBMITTED' AND v_target IN ('ACKNOWLEDGED','RESOLVED'))
    OR (v_query.status='ACKNOWLEDGED' AND v_target='RESOLVED')
    OR (v_query.status='RESOLVED' AND v_target='CLOSED')
  ) THEN
    RAISE EXCEPTION 'GENERAL_QUERY_STATUS_TRANSITION_INVALID: % -> %',v_query.status,v_target
      USING ERRCODE='55000';
  END IF;

  UPDATE public.customer_general_queries
  SET status=v_target,
      customer_response=CASE
        WHEN v_response IS NOT NULL THEN v_response
        ELSE customer_response
      END,
      responded_at=CASE
        WHEN v_response IS NOT NULL THEN statement_timestamp()
        ELSE responded_at
      END,
      responded_by=CASE
        WHEN v_response IS NOT NULL THEN v_actor
        ELSE responded_by
      END,
      updated_at=statement_timestamp()
  WHERE id=p_query_id
  RETURNING * INTO v_query;

  v_payload:=jsonb_build_object(
    'query_id',v_query.id,
    'status',v_query.status,
    'customer_response',v_query.customer_response
  );
  INSERT INTO public.customer_general_query_idempotency(
    idempotency_key,query_id,operation,request_fingerprint,response,actor_id
  ) VALUES(
    v_key,v_query.id,'STATUS_CHANGE',v_fingerprint,v_payload,v_actor
  );

  RETURN QUERY SELECT v_query.id,v_query.status,v_query.customer_response,false;
END;
$$;
REVOKE ALL ON FUNCTION public.manage_customer_general_query_v1(uuid,text,text,text,uuid)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.manage_customer_general_query_v1(uuid,text,text,text,uuid)
  TO authenticated;
COMMENT ON FUNCTION public.manage_customer_general_query_v1(uuid,text,text,text,uuid) IS
  'Internal-staff governed lifecycle for orderless customer enquiries. Enforces forward-only status transitions and actor-bound idempotency; RESOLVED/CLOSED require a customer-visible response.';

-- Replace only the buyer read projection so resolution is visible to the caller.
DROP FUNCTION IF EXISTS public.customer_general_queries_v1();
CREATE FUNCTION public.customer_general_queries_v1()
RETURNS TABLE(
  query_id uuid,
  category text,
  subject text,
  message text,
  status text,
  customer_response text,
  responded_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  SELECT
    q.id,q.category,q.subject,q.message,q.status,
    q.customer_response,q.responded_at,q.created_at,q.updated_at
  FROM public.customer_general_queries q
  WHERE q.user_id=auth.uid()
    AND q.company_id=public.customer_buyer_eligible_company_id()
  ORDER BY q.created_at DESC,q.id;
$$;
REVOKE ALL ON FUNCTION public.customer_general_queries_v1()
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.customer_general_queries_v1()
  TO authenticated;
COMMENT ON FUNCTION public.customer_general_queries_v1() IS
  'Buyer-company scoped general enquiry projection including only the customer-visible internal response and response timestamp.';
