-- APP-E2E hardening: bind canonical SO allocation to explicit governed creation scopes.
--
-- The initial numbering migration must not trust current_user='postgres': every
-- postgres-owned SECURITY DEFINER function runs with that effective role. Runtime
-- SO creation is therefore authorized by a private transaction-local capability
-- written only by the two canonical order-creation RPCs. Historical/local pgTAP
-- fixtures may preserve an explicit synthetic number only from a direct postgres
-- maintenance session with no authenticated JWT context; that path is unreachable
-- from authenticated SECURITY DEFINER execution.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE TABLE IF NOT EXISTS public.sales_order_creation_scopes (
  backend_pid integer NOT NULL,
  transaction_id bigint NOT NULL,
  authority text NOT NULL CHECK(authority IN ('CUSTOMER_CHECKOUT','WHATSAPP_DRAFT_PROMOTION')),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  PRIMARY KEY(backend_pid,transaction_id)
);
ALTER TABLE public.sales_order_creation_scopes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_order_creation_scopes FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON TABLE public.sales_order_creation_scopes IS
  'Private transaction-local capability proving that the current orders INSERT originated inside an approved canonical SO creation RPC.';

CREATE OR REPLACE FUNCTION public.assign_order_number_on_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_authority text;
  v_jwt_role text:=nullif(current_setting('request.jwt.claim.role',true),'');
  v_jwt_sub text:=nullif(current_setting('request.jwt.claim.sub',true),'');
BEGIN
  SELECT s.authority INTO v_authority
  FROM public.sales_order_creation_scopes s
  WHERE s.backend_pid=pg_backend_pid()
    AND s.transaction_id=txid_current();

  IF NEW.order_number IS NOT NULL AND btrim(NEW.order_number)<>'' THEN
    -- Existing migration/replay and pgTAP fixtures execute directly as postgres
    -- before any JWT claims are installed. Authenticated runtime calls retain the
    -- caller claims across SECURITY DEFINER and can never enter this branch.
    IF session_user='postgres'
       AND current_user='postgres'
       AND auth.uid() IS NULL
       AND v_jwt_role IS NULL
       AND v_jwt_sub IS NULL
       AND v_authority IS NULL THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'SO_NUMBER_SERVER_ASSIGNED' USING ERRCODE='42501';
  END IF;

  IF v_authority NOT IN ('CUSTOMER_CHECKOUT','WHATSAPP_DRAFT_PROMOTION') THEN
    RAISE EXCEPTION 'SALES_ORDER_CREATION_RPC_REQUIRED' USING ERRCODE='42501';
  END IF;

  NEW.order_number:=public.allocate_commercial_document_number_v1('SO');
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.assign_order_number_on_insert() FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON FUNCTION public.assign_order_number_on_insert() IS
  'Canonical SO assignment trigger. Runtime allocation requires a private transaction-local creation scope from an approved RPC; authenticated SECURITY DEFINER execution cannot rely on postgres role identity alone.';

CREATE OR REPLACE FUNCTION public.submit_customer_order_v1(
  p_idempotency_key text,
  p_requested_dispatch_date date DEFAULT NULL
)
RETURNS TABLE(
  order_id uuid,
  order_number text,
  sales_order_value numeric,
  advance_required numeric,
  draft_id uuid,
  is_duplicate_submission boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog,public,auth,extensions
AS $$
#variable_conflict use_column
DECLARE
  v_uid uuid:=auth.uid();
  v_company_id uuid;
  v_draft public.customer_order_drafts%rowtype;
  v_existing_order_id uuid;
  v_existing_order_number text;
  v_existing_so_value numeric;
  v_existing_advance numeric;
  v_promoted_draft_id uuid;
  v_order_id uuid;
  v_order_number text;
  v_snapshot jsonb:='[]'::jsonb;
  v_line record;
  v_auth record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: authentication is required' USING ERRCODE='28000';
  END IF;
  IF coalesce(btrim(p_idempotency_key),'')='' THEN
    RAISE EXCEPTION 'VALIDATION_FAILED: idempotency_key is required';
  END IF;

  v_company_id:=public.customer_buyer_eligible_company_id();
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' USING ERRCODE='42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('customer_checkout:'||v_company_id::text||':'||btrim(p_idempotency_key),0)
  );

  SELECT o.id,o.order_number,o.sales_order_value,o.advance_required
  INTO v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance
  FROM public.orders o
  WHERE o.company_id=v_company_id
    AND o.order_origin='CUSTOMER_APP'
    AND o.checkout_idempotency_key=btrim(p_idempotency_key)
  LIMIT 1;

  IF v_existing_order_id IS NOT NULL THEN
    SELECT d.id INTO v_promoted_draft_id
    FROM public.customer_order_drafts d
    WHERE d.promoted_order_id=v_existing_order_id
    LIMIT 1;
    RETURN QUERY SELECT
      v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance,
      v_promoted_draft_id,true;
    RETURN;
  END IF;

  SELECT * INTO v_draft
  FROM public.customer_order_drafts d
  WHERE d.company_id=v_company_id AND d.status='active'
  ORDER BY d.updated_at DESC, d.created_at DESC, d.id
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DRAFT_NOT_FOUND: no active customer order draft exists for checkout' USING ERRCODE='P0002';
  END IF;

  PERFORM public.customer_order_draft_audit_v1(
    v_draft.id,v_company_id,v_uid,'SUBMIT_ATTEMPT',
    jsonb_build_object('idempotency_key',btrim(p_idempotency_key))
  );
  PERFORM public.customer_recompute_draft_readiness_v1(v_draft.id);
  SELECT * INTO v_draft FROM public.customer_order_drafts WHERE id=v_draft.id;
  IF v_draft.readiness_status<>'ready' THEN
    RAISE EXCEPTION 'DRAFT_NOT_READY: draft cannot be submitted (issues: %)',v_draft.readiness_issues::text;
  END IF;

  FOR v_line IN
    SELECT l.* FROM public.customer_order_draft_lines l WHERE l.draft_id=v_draft.id
  LOOP
    SELECT * INTO v_auth
    FROM public.customer_resolve_buyer_product_authority_v1(v_company_id,v_line.product_id);
    IF NOT coalesce(v_auth.is_available,false) THEN
      RAISE EXCEPTION 'PRODUCT_UNAVAILABLE: product % is not available at checkout',v_line.product_id;
    END IF;
    IF NOT public.customer_validate_order_quantity_v1(
      v_line.quantity,v_auth.minimum_order_quantity,v_auth.order_increment,v_auth.min_carton_qty
    ) THEN
      RAISE EXCEPTION 'QUANTITY_RULE_VIOLATION: product % failed MOQ/increment/carton validation at checkout',v_line.product_id;
    END IF;
    v_snapshot:=v_snapshot||jsonb_build_array(jsonb_build_object(
      'product_id',v_line.product_id,
      'quantity',v_line.quantity,
      'selling_price',v_auth.selling_price,
      'currency',v_auth.currency,
      'uom',v_auth.uom,
      'gst_rate',v_auth.gst_rate,
      'tax_inclusive',v_auth.tax_inclusive,
      'sku',v_auth.sku,
      'product_name',v_auth.product_name,
      'minimum_order_quantity',v_auth.minimum_order_quantity,
      'order_increment',v_auth.order_increment,
      'min_carton_qty',v_auth.min_carton_qty
    ));
  END LOOP;

  INSERT INTO public.sales_order_creation_scopes(backend_pid,transaction_id,authority)
  VALUES(pg_backend_pid(),txid_current(),'CUSTOMER_CHECKOUT')
  ON CONFLICT(backend_pid,transaction_id) DO UPDATE
    SET authority=EXCLUDED.authority,created_at=statement_timestamp();

  INSERT INTO public.orders(
    company_id,status,order_origin,checkout_idempotency_key,checkout_snapshot,
    requested_dispatch_date,tracking_token
  ) VALUES(
    v_company_id,'submitted','CUSTOMER_APP',btrim(p_idempotency_key),v_snapshot,
    p_requested_dispatch_date,encode(extensions.gen_random_bytes(16),'hex')
  ) RETURNING id,order_number INTO v_order_id,v_order_number;

  DELETE FROM public.sales_order_creation_scopes
  WHERE backend_pid=pg_backend_pid() AND transaction_id=txid_current();

  FOR v_line IN
    SELECT l.* FROM public.customer_order_draft_lines l WHERE l.draft_id=v_draft.id
  LOOP
    INSERT INTO public.order_items(order_id,product_id,quantity,pack_size)
    VALUES(v_order_id,v_line.product_id,v_line.quantity,v_line.uom_snapshot);
  END LOOP;

  PERFORM public.recalculate_customer_app_order_financials(v_order_id);
  UPDATE public.customer_order_drafts
  SET status='promoted',promoted_order_id=v_order_id,updated_at=now()
  WHERE id=v_draft.id;
  PERFORM public.customer_order_draft_audit_v1(
    v_draft.id,v_company_id,v_uid,'PROMOTE',
    jsonb_build_object('order_id',v_order_id,'idempotency_key',btrim(p_idempotency_key))
  );

  RETURN QUERY
  SELECT v_order_id,v_order_number,o.sales_order_value,o.advance_required,v_draft.id,false
  FROM public.orders o WHERE o.id=v_order_id;
EXCEPTION
  WHEN unique_violation THEN
    SELECT o.id,o.order_number,o.sales_order_value,o.advance_required
    INTO v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance
    FROM public.orders o
    WHERE o.company_id=v_company_id
      AND o.order_origin='CUSTOMER_APP'
      AND o.checkout_idempotency_key=btrim(p_idempotency_key)
    LIMIT 1;
    IF v_existing_order_id IS NULL THEN RAISE; END IF;
    SELECT d.id INTO v_promoted_draft_id
    FROM public.customer_order_drafts d
    WHERE d.promoted_order_id=v_existing_order_id
    LIMIT 1;
    RETURN QUERY SELECT
      v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance,
      v_promoted_draft_id,true;
END;
$$;

CREATE OR REPLACE FUNCTION public.promote_sales_order_draft_to_order_governed_v1(
  p_draft_id uuid,
  p_expected_extraction_request_key text,
  p_actor_id uuid,
  p_actor_name text,
  p_review_notes text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE(
  draft_id uuid,
  promoted_order_id uuid,
  order_number text,
  already_promoted boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,extensions
AS $$
#variable_conflict use_column
DECLARE
  v_draft public.sales_order_drafts%rowtype;
  v_order_id uuid;
  v_order_number text;
  v_line record;
  v_qty numeric;
  v_lines int:=0;
BEGIN
  SELECT * INTO v_draft FROM public.sales_order_drafts d WHERE d.id=p_draft_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  IF v_draft.extraction_request_key IS DISTINCT FROM btrim(p_expected_extraction_request_key) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_MISMATCH' USING ERRCODE='P0001';
  END IF;
  IF v_draft.promoted_order_id IS NOT NULL THEN
    SELECT o.order_number INTO v_order_number FROM public.orders o WHERE o.id=v_draft.promoted_order_id;
    RETURN QUERY SELECT p_draft_id,v_draft.promoted_order_id,v_order_number,true;
    RETURN;
  END IF;
  IF v_draft.status<>'UNDER_REVIEW' OR v_draft.company_id IS NULL THEN
    RAISE EXCEPTION 'DRAFT_NOT_READY' USING ERRCODE='P0001';
  END IF;
  PERFORM public.validate_sales_order_draft_readiness(v_draft.readiness_dimensions);
  PERFORM 1 FROM public.sales_order_draft_lines l WHERE l.draft_id=p_draft_id FOR UPDATE;
  SELECT count(*) INTO v_lines
  FROM public.sales_order_draft_lines l
  WHERE l.draft_id=p_draft_id
    AND l.product_id IS NOT NULL
    AND coalesce(l.operator_quantity,l.normalized_quantity,l.raw_quantity,0)>0;
  IF v_lines=0 THEN RAISE EXCEPTION 'DRAFT_HAS_NO_VALID_LINES' USING ERRCODE='P0001'; END IF;

  INSERT INTO public.sales_order_creation_scopes(backend_pid,transaction_id,authority)
  VALUES(pg_backend_pid(),txid_current(),'WHATSAPP_DRAFT_PROMOTION')
  ON CONFLICT(backend_pid,transaction_id) DO UPDATE
    SET authority=EXCLUDED.authority,created_at=statement_timestamp();

  INSERT INTO public.orders(company_id,status,order_origin,payment_status,tracking_token)
  VALUES(v_draft.company_id,'submitted','WHATSAPP','awaiting_receipt',encode(extensions.gen_random_bytes(16),'hex'))
  RETURNING id,public.orders.order_number INTO v_order_id,v_order_number;

  DELETE FROM public.sales_order_creation_scopes
  WHERE backend_pid=pg_backend_pid() AND transaction_id=txid_current();

  FOR v_line IN
    SELECT l.* FROM public.sales_order_draft_lines l WHERE l.draft_id=p_draft_id ORDER BY l.line_index
  LOOP
    v_qty:=coalesce(v_line.operator_quantity,v_line.normalized_quantity,v_line.raw_quantity,0);
    IF v_line.product_id IS NOT NULL AND v_qty>0 THEN
      INSERT INTO public.order_items(order_id,product_id,quantity,pack_size,notes)
      VALUES(v_order_id,v_line.product_id,v_qty,coalesce(v_line.normalized_unit,v_line.raw_unit),left(coalesce(v_line.product_name,''),500));
    END IF;
  END LOOP;

  PERFORM public.restore_order_financials(v_order_id);
  UPDATE public.sales_order_drafts d
  SET promoted_order_id=v_order_id,updated_by=p_actor_id,updated_at=statement_timestamp()
  WHERE d.id=p_draft_id;
  PERFORM public.create_sales_order_commercial_version_v1(
    v_order_id,'WHATSAPP_DRAFT_PROMOTION','wa-draft:'||p_draft_id::text,
    'wa-so-version:'||p_draft_id::text,p_actor_id
  );
  UPDATE public.sales_order_drafts d
  SET status='APPROVED_FOR_SO',approver_id=p_actor_id,approver_name=p_actor_name,
      review_notes=p_review_notes,updated_by=p_actor_id,updated_at=statement_timestamp()
  WHERE d.id=p_draft_id;
  INSERT INTO public.sales_order_draft_audit_log(
    draft_id,action,from_status,to_status,actor_id,actor_name,metadata
  ) VALUES(
    p_draft_id,'APPROVE','UNDER_REVIEW','APPROVED_FOR_SO',p_actor_id,p_actor_name,
    coalesce(p_metadata,'{}'::jsonb)||jsonb_build_object('promoted_order_id',v_order_id)
  );
  INSERT INTO public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value)
  VALUES(
    'WA_DRAFT_PROMOTED_TO_SO','WhatsApp','orders',v_order_id::text,p_actor_id,'high',
    jsonb_build_object('draft_id',p_draft_id)
  );
  RETURN QUERY SELECT p_draft_id,v_order_id,v_order_number,false;
END;
$$;

-- Privileges on the existing RPC signatures are intentionally preserved by
-- CREATE OR REPLACE; the private scope table itself remains inaccessible.
