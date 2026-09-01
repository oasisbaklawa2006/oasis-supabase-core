-- APP-E2E remaining buyer contracts: safe documents/statement, durable favourites,
-- and general non-order enquiry capture.
--
-- General enquiries intentionally have no order_id and never invoke Sales Order
-- creation. Existing support_tickets remain order-bound and are not broadened.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

-- -----------------------------------------------------------------------------
-- A. Customer-safe document and statement contracts
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.customer_documents_v1()
RETURNS TABLE(
  document_type text,
  document_id uuid,
  document_number text,
  order_id uuid,
  order_number text,
  commercial_version_id uuid,
  status text,
  issued_at timestamptz,
  customer_total numeric,
  availability_state text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  WITH buyer AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  ), buyer_orders AS (
    SELECT o.*
    FROM public.orders o
    JOIN buyer b ON b.company_id IS NOT NULL AND b.company_id=o.company_id
    WHERE coalesce(o.is_waste,false)=false
      AND coalesce(o.is_duplicate,false)=false
  ), current_versions AS (
    SELECT v.*
    FROM public.sales_order_commercial_versions v
    JOIN buyer_orders o ON o.id=v.order_id AND o.commercial_current_version=v.version_number
  ), pi_rows AS (
    SELECT p.*,o.order_number
    FROM public.sales_order_proforma_invoices p
    JOIN buyer_orders o ON o.id=p.order_id
  ), invoice_rows AS (
    SELECT f.*,o.order_number
    FROM public.final_invoices f
    JOIN buyer_orders o ON o.id=f.order_id
  )
  SELECT
    'SALES_ORDER'::text,
    v.id,
    o.order_number,
    o.id,
    o.order_number,
    v.id,
    'ISSUED'::text,
    v.created_at,
    v.sales_order_value,
    'issued'::text
  FROM buyer_orders o
  JOIN current_versions v ON v.order_id=o.id

  UNION ALL

  SELECT
    'PROFORMA_INVOICE'::text,
    p.id,
    CASE WHEN p.status='ISSUED' THEN p.customer_visible_pi_number ELSE NULL END,
    p.order_id,
    p.order_number,
    p.commercial_version_id,
    p.status,
    CASE WHEN p.status='ISSUED' THEN p.issued_at ELSE NULL END,
    (p.frozen_commercial_snapshot->>'sales_order_value')::numeric,
    CASE
      WHEN p.status='ISSUED' THEN 'issued'
      WHEN p.status IN ('DRAFT','READY_FOR_ISSUE') THEN 'preparing'
      ELSE 'unavailable'
    END::text
  FROM pi_rows p

  UNION ALL

  SELECT
    'FINAL_INVOICE'::text,
    f.id,
    CASE WHEN f.status='ISSUED' THEN f.invoice_number ELSE NULL END,
    o.id,
    o.order_number,
    coalesce(f.commercial_version_id,v.id),
    coalesce(f.status,'NOT_ISSUED')::text,
    CASE WHEN f.status='ISSUED' THEN f.created_at ELSE NULL END,
    CASE WHEN f.status='ISSUED' THEN f.gross_total ELSE NULL END,
    CASE WHEN f.status='ISSUED' THEN 'issued' ELSE 'preparing' END::text
  FROM buyer_orders o
  LEFT JOIN current_versions v ON v.order_id=o.id
  LEFT JOIN LATERAL (
    SELECT fi.*
    FROM invoice_rows fi
    WHERE fi.order_id=o.id
    ORDER BY CASE fi.status WHEN 'ISSUED' THEN 0 ELSE 1 END,fi.created_at DESC,fi.id DESC
    LIMIT 1
  ) f ON true
  ORDER BY 4,1,8 NULLS LAST;
$$;
REVOKE ALL ON FUNCTION public.customer_documents_v1() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.customer_documents_v1() TO authenticated;
COMMENT ON FUNCTION public.customer_documents_v1() IS
  'Buyer-company scoped document facts. Exposes immutable issued SO/PI/final-invoice identities and safe preparing/unavailable states only; never exposes document_reference, storage paths, audit metadata or predicted numbers.';

CREATE OR REPLACE FUNCTION public.customer_statement_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_company_id uuid:=public.customer_buyer_eligible_company_id();
  v_raw jsonb;
  v_entries jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_company_id IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_STATEMENT_COMPANY_CONTEXT_REQUIRED' USING ERRCODE='42501';
  END IF;

  v_raw:=public.get_customer_financial_360_v1(v_company_id);
  SELECT coalesce(jsonb_agg(e.value-'commercial_closure_id'),'[]'::jsonb)
    INTO v_entries
    FROM jsonb_array_elements(coalesce(v_raw->'orders','[]'::jsonb)) e(value);

  RETURN jsonb_build_object(
    'company_id',v_company_id,
    'wallet_balance',v_raw->'wallet_balance',
    'entries',v_entries,
    'facts_as_of',v_raw->'facts_as_of',
    'statement_facts_only',true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.customer_statement_v1() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.customer_statement_v1() TO authenticated;
COMMENT ON FUNCTION public.customer_statement_v1() IS
  'Customer-safe statement/ledger projection composed from canonical financial 360. Removes internal commercial closure identifiers and returns facts only.';

-- -----------------------------------------------------------------------------
-- B. Durable buyer favourites
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.customer_product_favourites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  product_id uuid NOT NULL REFERENCES public.products(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE(user_id,company_id,product_id)
);
ALTER TABLE public.customer_product_favourites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_product_favourites FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON TABLE public.customer_product_favourites IS
  'Private durable buyer favourites. Identity is scoped to authenticated buyer user + eligible company + product; mutations occur only through governed RPCs.';

CREATE OR REPLACE FUNCTION public.set_customer_product_favourite_v1(
  p_product_id uuid,
  p_is_favourite boolean
) RETURNS TABLE(
  product_id uuid,
  is_favourite boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_uid uuid:=auth.uid();
  v_company_id uuid:=public.customer_buyer_eligible_company_id();
  v_available boolean;
BEGIN
  IF v_uid IS NULL OR v_company_id IS NULL THEN
    RAISE EXCEPTION 'FAVOURITE_BUYER_CONTEXT_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF p_product_id IS NULL OR p_is_favourite IS NULL THEN
    RAISE EXCEPTION 'FAVOURITE_INPUT_REQUIRED' USING ERRCODE='22023';
  END IF;

  IF p_is_favourite THEN
    SELECT coalesce(a.is_available,false) INTO v_available
    FROM public.customer_resolve_buyer_product_authority_v1(v_company_id,p_product_id) a;
    IF NOT coalesce(v_available,false) THEN
      RAISE EXCEPTION 'FAVOURITE_PRODUCT_NOT_AVAILABLE' USING ERRCODE='P0001';
    END IF;
    INSERT INTO public.customer_product_favourites(company_id,user_id,product_id)
    VALUES(v_company_id,v_uid,p_product_id)
    ON CONFLICT(user_id,company_id,product_id) DO NOTHING;
  ELSE
    DELETE FROM public.customer_product_favourites
    WHERE company_id=v_company_id AND user_id=v_uid AND product_id=p_product_id;
  END IF;

  RETURN QUERY SELECT p_product_id,p_is_favourite;
END;
$$;
REVOKE ALL ON FUNCTION public.set_customer_product_favourite_v1(uuid,boolean)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.set_customer_product_favourite_v1(uuid,boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_product_favourites_v1()
RETURNS TABLE(product_id uuid,created_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  SELECT f.product_id,f.created_at
  FROM public.customer_product_favourites f
  WHERE f.user_id=auth.uid()
    AND f.company_id=public.customer_buyer_eligible_company_id()
  ORDER BY f.created_at DESC,f.product_id;
$$;
REVOKE ALL ON FUNCTION public.customer_product_favourites_v1()
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.customer_product_favourites_v1()
  TO authenticated;

-- -----------------------------------------------------------------------------
-- C. General/non-order customer query capture
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.customer_general_queries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  category text NOT NULL CHECK(category IN ('GENERAL','CATALOGUE','ACCOUNT','DELIVERY','OTHER')),
  subject text NOT NULL CHECK(length(subject) BETWEEN 3 AND 200),
  message text NOT NULL CHECK(length(message) BETWEEN 10 AND 4000),
  status text NOT NULL DEFAULT 'SUBMITTED' CHECK(status IN ('SUBMITTED','ACKNOWLEDGED','RESOLVED','CLOSED')),
  idempotency_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE(company_id,user_id,idempotency_key)
);
ALTER TABLE public.customer_general_queries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_general_queries FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON TABLE public.customer_general_queries IS
  'Orderless customer enquiry capture. This table has deliberately no order_id and no Sales Order creation trigger; a valid enquiry is captured exactly once without becoming an order.';

CREATE OR REPLACE FUNCTION public.submit_customer_general_query_v1(
  p_idempotency_key text,
  p_subject text,
  p_message text,
  p_category text DEFAULT 'GENERAL'
) RETURNS TABLE(
  query_id uuid,
  status text,
  is_duplicate_submission boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_uid uuid:=auth.uid();
  v_company_id uuid:=public.customer_buyer_eligible_company_id();
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_subject text:=btrim(coalesce(p_subject,''));
  v_message text:=btrim(coalesce(p_message,''));
  v_category text:=upper(btrim(coalesce(p_category,'GENERAL')));
  v_existing public.customer_general_queries%rowtype;
BEGIN
  IF v_uid IS NULL OR v_company_id IS NULL THEN
    RAISE EXCEPTION 'GENERAL_QUERY_BUYER_CONTEXT_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF v_key='' OR length(v_key)>200 THEN
    RAISE EXCEPTION 'GENERAL_QUERY_IDEMPOTENCY_KEY_REQUIRED' USING ERRCODE='22023';
  END IF;
  IF length(v_subject)<3 OR length(v_subject)>200
     OR length(v_message)<10 OR length(v_message)>4000
     OR v_category NOT IN ('GENERAL','CATALOGUE','ACCOUNT','DELIVERY','OTHER') THEN
    RAISE EXCEPTION 'GENERAL_QUERY_VALIDATION_FAILED' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'customer-general-query:'||v_company_id::text||':'||v_uid::text||':'||v_key,0
  ));

  SELECT * INTO v_existing
  FROM public.customer_general_queries
  WHERE company_id=v_company_id AND user_id=v_uid AND idempotency_key=v_key;
  IF FOUND THEN
    IF v_existing.subject IS DISTINCT FROM v_subject
       OR v_existing.message IS DISTINCT FROM v_message
       OR v_existing.category IS DISTINCT FROM v_category THEN
      RAISE EXCEPTION 'GENERAL_QUERY_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.status,true;
    RETURN;
  END IF;

  INSERT INTO public.customer_general_queries(
    company_id,user_id,category,subject,message,idempotency_key
  ) VALUES(
    v_company_id,v_uid,v_category,v_subject,v_message,v_key
  ) RETURNING * INTO v_existing;

  RETURN QUERY SELECT v_existing.id,v_existing.status,false;
END;
$$;
REVOKE ALL ON FUNCTION public.submit_customer_general_query_v1(text,text,text,text)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.submit_customer_general_query_v1(text,text,text,text)
  TO authenticated;
COMMENT ON FUNCTION public.submit_customer_general_query_v1(text,text,text,text) IS
  'Captures one authenticated buyer-company general enquiry per idempotency key. It never inserts, promotes or references public.orders.';

CREATE OR REPLACE FUNCTION public.customer_general_queries_v1()
RETURNS TABLE(
  query_id uuid,
  category text,
  subject text,
  message text,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  SELECT q.id,q.category,q.subject,q.message,q.status,q.created_at,q.updated_at
  FROM public.customer_general_queries q
  WHERE q.user_id=auth.uid()
    AND q.company_id=public.customer_buyer_eligible_company_id()
  ORDER BY q.created_at DESC,q.id;
$$;
REVOKE ALL ON FUNCTION public.customer_general_queries_v1()
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.customer_general_queries_v1()
  TO authenticated;
