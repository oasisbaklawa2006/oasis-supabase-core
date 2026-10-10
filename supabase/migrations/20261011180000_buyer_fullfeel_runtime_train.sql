-- Buyer full-feel runtime train.
-- Created with Supabase CLI as 20261011180000_buyer_fullfeel_runtime_train.sql.
-- Consolidates still-needed pending certification repairs from stale PRs
-- #379/#383/#388/#389/#390, with reviewed defects corrected, and adds
-- governed Buyer saved-address / saved-transporter write authority plus
-- server-only payment-provider adapter helpers.
--
-- No seed/business data is invented. No payment-provider credential is stored here.
-- Live provider activation remains fail-closed until Edge runtime secrets exist.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- A. WhatsApp packet-AI terminal retry governance (supersedes PR #379).
ALTER TABLE public.whatsapp_packet_ai_dispatch_jobs
  DROP CONSTRAINT IF EXISTS whatsapp_packet_ai_dispatch_jobs_state_check;

ALTER TABLE public.whatsapp_packet_ai_dispatch_jobs
  ADD CONSTRAINT whatsapp_packet_ai_dispatch_jobs_state_check
  CHECK (state IN (
    'QUEUED','LEASED','RETRY','BLOCKED_KNOWLEDGE_AUTHORITY','BLOCKED_PERMANENT','COMPLETED'
  ));

CREATE OR REPLACE FUNCTION public.retry_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid,
  p_lease_token uuid,
  p_packet_revision bigint,
  p_error_code text,
  p_error_detail text DEFAULT NULL,
  p_knowledge_authority_failure boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype;
  v_case_id uuid;
  v_code text := left(btrim(coalesce(p_error_code,'')),120);
  v_detail text := left(btrim(coalesce(p_error_detail,'')),500);
BEGIN
  IF v_code='' THEN
    RAISE EXCEPTION 'error code required' USING ERRCODE='22023';
  END IF;

  UPDATE public.whatsapp_packet_ai_dispatch_jobs j
  SET
    state = CASE
      WHEN p_knowledge_authority_failure THEN 'BLOCKED_KNOWLEDGE_AUTHORITY'
      WHEN v_code = 'INTERPRETATION_PACKET_TOO_LARGE' THEN 'BLOCKED_PERMANENT'
      WHEN j.attempt_count >= 5 THEN 'BLOCKED_PERMANENT'
      ELSE 'RETRY'
    END,
    claimed_at = NULL,
    lease_expires_at = NULL,
    lease_token = NULL,
    last_error_code = v_code,
    last_error_detail = nullif(v_detail,''),
    next_retry_at = CASE
      WHEN p_knowledge_authority_failure THEN
        statement_timestamp()+make_interval(secs=>least(900,15*power(2,least(j.attempt_count,5))::integer))
      WHEN v_code = 'INTERPRETATION_PACKET_TOO_LARGE' OR j.attempt_count >= 5 THEN
        'infinity'::timestamptz
      ELSE
        statement_timestamp()+make_interval(secs=>least(900,15*power(2,least(j.attempt_count,5))::integer))
    END,
    updated_at = statement_timestamp()
  WHERE j.id=p_job_id
    AND j.state='LEASED'
    AND j.lease_token=p_lease_token
    AND j.packet_revision=p_packet_revision
    AND j.lease_expires_at > statement_timestamp()
    AND (
      j.execution_kind='PACKET'
      OR EXISTS(
        SELECT 1 FROM public.whatsapp_communication_cases c
        WHERE c.id=j.case_id AND c.context_revision=j.context_revision
      )
    )
  RETURNING j.* INTO v_job;

  IF NOT FOUND THEN RETURN false; END IF;

  IF v_job.state='BLOCKED_PERMANENT' THEN
    v_case_id := v_job.case_id;
    IF v_case_id IS NULL THEN
      INSERT INTO public.whatsapp_communication_cases (
        packet_id,case_type,status,accountable_team,accountability_status,
        next_action,next_action_due_at,source_channel,rule_version
      ) VALUES (
        v_job.packet_id,'UNCLASSIFIED','NEEDS_IDENTITY','OPERATIONS','UNASSIGNED',
        'Manual review required: packet AI processing blocked ('||v_code||').',
        statement_timestamp()+interval '1 hour','WHATSAPP','packet-ai-terminal-v1'
      )
      ON CONFLICT (packet_id) DO NOTHING
      RETURNING id INTO v_case_id;

      IF v_case_id IS NULL THEN
        SELECT c.id INTO v_case_id
        FROM public.whatsapp_communication_cases c
        WHERE c.packet_id=v_job.packet_id;
      END IF;
    END IF;

    IF v_case_id IS NOT NULL THEN
      UPDATE public.whatsapp_communication_cases c
      SET
        next_action = CASE
          WHEN c.status IN ('CLOSED','CANCELLED') THEN c.next_action
          ELSE 'Manual review required: packet AI processing blocked ('||v_code||').'
        END,
        next_action_due_at = CASE
          WHEN c.status IN ('CLOSED','CANCELLED') THEN c.next_action_due_at
          ELSE least(
            coalesce(c.next_action_due_at,statement_timestamp()+interval '1 hour'),
            statement_timestamp()+interval '1 hour'
          )
        END,
        updated_at=statement_timestamp()
      WHERE c.id=v_case_id;

      INSERT INTO public.whatsapp_case_events (
        case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata
      ) VALUES (
        v_case_id,'PACKET_AI_TERMINAL_BLOCKED',NULL,'SYSTEM',
        'packet-ai-terminal:'||p_job_id::text||':'||p_packet_revision::text,
        jsonb_build_object('packet_ai_state','BLOCKED_PERMANENT','human_review_required',true),
        jsonb_build_object(
          'packet_id',v_job.packet_id,
          'dispatch_job_id',v_job.id,
          'error_code',v_code,
          'error_detail',nullif(v_detail,''),
          'attempt_count',v_job.attempt_count,
          'automatic_commercial_action',false
        )
      )
      ON CONFLICT (case_id,correlation_key) DO NOTHING;
    END IF;
  END IF;

  RETURN true;
END
$$;

REVOKE ALL ON FUNCTION public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)
  TO service_role;

-- B. Exhaustive product-history hard-delete guard (supersedes PR #383).
CREATE OR REPLACE FUNCTION public.guard_referenced_product_hard_delete_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF coalesce(old.is_active,false) THEN
    RAISE EXCEPTION 'PRODUCT_HARD_DELETE_FORBIDDEN: deactivate/archive active product first'
      USING ERRCODE='23503';
  END IF;

  IF EXISTS (SELECT 1 FROM public.order_items x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.production_jobs x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.catalogue_versions x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.daily_production_logs x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.inventory_adjustments x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.packing_lists x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.order_returns x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.production_rgs_transfers x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.customer_quotation_lines x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.whatsapp_sales_order_drafts x WHERE x.resolved_product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.catalogue_ai_studio_drafts x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.catalogue_product_mappings x WHERE x.central_product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.catalogue_source_entries x WHERE x.matched_product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.factory_inventory x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.product_aliases x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.product_bom x WHERE x.product_id=old.id OR x.component_product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.product_media x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.product_moq_rules x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.product_pricing_rules x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.product_tag_mapping x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.product_variants x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.product_variants_legacy_pre_point32 x WHERE x.product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.products x WHERE x.basis_product_id=old.id)
     OR EXISTS (SELECT 1 FROM public.sales_requests x WHERE x.product_id=old.id)
  THEN
    RAISE EXCEPTION 'PRODUCT_HARD_DELETE_FORBIDDEN: referenced product must be archived/deactivated to preserve historical identity'
      USING ERRCODE='23503';
  END IF;

  RETURN old;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_referenced_product_hard_delete_v1()
  FROM PUBLIC,anon,authenticated,service_role;

DROP TRIGGER IF EXISTS trg_guard_referenced_product_hard_delete_v1 ON public.products;
CREATE TRIGGER trg_guard_referenced_product_hard_delete_v1
BEFORE DELETE ON public.products
FOR EACH ROW EXECUTE FUNCTION public.guard_referenced_product_hard_delete_v1();

-- C. Production department mutation authority (supersedes PR #388).
CREATE OR REPLACE FUNCTION public.dispatch_production_to_rgs(
  p_job_id uuid,
  p_dispatched_qty numeric,
  p_correlation_id text,
  p_destination_store_code text DEFAULT 'FINISHED_GOODS'
)
RETURNS public.production_rgs_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_job public.production_jobs%rowtype;
  v_transfer public.production_rgs_transfers%rowtype;
  v_product_sku text;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id=v_actor_id;
  IF v_actor_id IS NULL OR public.is_internal_staff(v_actor_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;
  IF nullif(btrim(p_correlation_id),'') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;

  IF (v_job.canonical_department IS NULL
      OR public.role_canonical_department(v_actor_role) IS NULL
      OR public.role_canonical_department(v_actor_role) <> v_job.canonical_department)
     AND public.is_inventory_receive_role(v_actor_role) IS NOT TRUE
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %',v_job.canonical_department USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_transfer
  FROM public.production_rgs_transfers
  WHERE correlation_id=p_correlation_id;
  IF FOUND THEN
    IF v_transfer.job_id IS DISTINCT FROM p_job_id THEN
      RAISE EXCEPTION 'Correlation id already used for a different job' USING ERRCODE='23505';
    END IF;
    RETURN v_transfer;
  END IF;

  IF v_job.status <> 'completed' OR NOT v_job.locked THEN
    RAISE EXCEPTION 'Job must be declared ready before dispatch to RGS';
  END IF;
  IF p_dispatched_qty IS NULL OR p_dispatched_qty <= 0 OR p_dispatched_qty > v_job.produced_qty THEN
    RAISE EXCEPTION 'Dispatched quantity must be positive and cannot exceed declared output';
  END IF;

  SELECT sku INTO v_product_sku FROM public.products WHERE id=v_job.product_id;

  INSERT INTO public.production_rgs_transfers(
    job_id,product_id,sku,quantity,declared_qty,batch_number,transferred_by,
    status,destination_store_code,correlation_id
  ) VALUES (
    p_job_id,v_job.product_id,v_product_sku,p_dispatched_qty,v_job.produced_qty,v_job.batch_number,v_actor_id,
    'in_transit',p_destination_store_code,p_correlation_id
  )
  RETURNING * INTO v_transfer;

  UPDATE public.production_jobs SET status='transferred',updated_at=now() WHERE id=p_job_id;
  RETURN v_transfer;
END;
$$;

CREATE OR REPLACE FUNCTION public.report_production_issue(
  p_job_id uuid,
  p_department text,
  p_issue_type text,
  p_comment text,
  p_photo_url text DEFAULT NULL,
  p_correlation_id text DEFAULT NULL
)
RETURNS public.production_issues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_existing public.production_issues%rowtype;
  v_issue public.production_issues%rowtype;
  v_severity text;
  v_correlation_id text := nullif(btrim(coalesce(p_correlation_id,'')),'');
  v_job_department text;
  v_job_canonical_department text;
  v_canonical_dept text;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id=v_actor_id;
  IF v_actor_id IS NULL OR public.is_internal_staff(v_actor_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised to report a production issue' USING ERRCODE='42501';
  END IF;
  IF p_job_id IS NULL THEN RAISE EXCEPTION 'A job_id is required'; END IF;
  IF nullif(btrim(coalesce(p_department,'')),'') IS NULL THEN RAISE EXCEPTION 'A department is required'; END IF;
  IF p_issue_type IS NULL OR p_issue_type NOT IN ('material','machine','delay') THEN
    RAISE EXCEPTION 'issue_type must be one of material, machine, delay';
  END IF;
  IF nullif(btrim(coalesce(p_comment,'')),'') IS NULL THEN
    RAISE EXCEPTION 'A comment describing the issue is required';
  END IF;
  IF v_correlation_id IS NULL THEN RAISE EXCEPTION 'A correlation id is required'; END IF;

  SELECT department,canonical_department
  INTO v_job_department,v_job_canonical_department
  FROM public.production_jobs
  WHERE id=p_job_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job % not found',p_job_id; END IF;

  IF (v_job_canonical_department IS NULL
      OR public.role_canonical_department(v_actor_role) IS NULL
      OR public.role_canonical_department(v_actor_role) <> v_job_canonical_department)
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %',v_job_canonical_department USING ERRCODE='42501';
  END IF;

  v_canonical_dept := public.canonical_production_department(p_department);
  IF v_canonical_dept IS NULL OR v_canonical_dept IS DISTINCT FROM v_job_canonical_department THEN
    RAISE EXCEPTION 'department % does not match production job %''s department',p_department,p_job_id;
  END IF;

  SELECT * INTO v_existing
  FROM public.production_issues
  WHERE correlation_id=v_correlation_id AND job_id=p_job_id;
  IF FOUND THEN RETURN v_existing; END IF;

  v_severity := CASE p_issue_type WHEN 'machine' THEN 'urgent' WHEN 'delay' THEN 'warning' ELSE 'warning' END;

  BEGIN
    INSERT INTO public.production_issues(job_id,department,issue_type,comment,photo_url,reported_by,correlation_id)
    VALUES (p_job_id,v_job_department,p_issue_type,btrim(p_comment),p_photo_url,v_actor_id,v_correlation_id)
    RETURNING * INTO v_issue;
  EXCEPTION WHEN unique_violation THEN
    SELECT * INTO v_existing
    FROM public.production_issues
    WHERE correlation_id=v_correlation_id AND job_id=p_job_id;
    IF FOUND THEN RETURN v_existing; END IF;
    RAISE;
  END;

  PERFORM public.append_operational_event_v1(
    p_event_type:='production_issue_escalation',
    p_entity_type:='production_issue',
    p_entity_id:=v_issue.id,
    p_title:='Production issue: '||p_issue_type||' ('||v_job_department||')',
    p_source_application:='production',
    p_correlation_id:=v_correlation_id,
    p_actor_id:=v_actor_id,
    p_actor_department:=v_job_department,
    p_severity:=v_severity,
    p_message:=btrim(p_comment),
    p_idempotency_key:='production-issue-escalation:'||v_correlation_id
  );

  RETURN v_issue;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_production_issue(
  p_issue_id uuid,
  p_resolution_notes text
)
RETURNS public.production_issues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_issue public.production_issues%rowtype;
  v_job_canonical_department text;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id=v_actor_id;
  IF v_actor_id IS NULL OR public.is_internal_staff(v_actor_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised to resolve a production issue' USING ERRCODE='42501';
  END IF;
  IF nullif(btrim(coalesce(p_resolution_notes,'')),'') IS NULL THEN
    RAISE EXCEPTION 'Resolution notes are required';
  END IF;

  SELECT * INTO v_issue FROM public.production_issues WHERE id=p_issue_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production issue % not found',p_issue_id; END IF;

  SELECT canonical_department INTO v_job_canonical_department
  FROM public.production_jobs
  WHERE id=v_issue.job_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job % not found',v_issue.job_id; END IF;

  IF (v_job_canonical_department IS NULL
      OR public.role_canonical_department(v_actor_role) IS NULL
      OR public.role_canonical_department(v_actor_role) <> v_job_canonical_department)
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %',v_job_canonical_department USING ERRCODE='42501';
  END IF;

  IF v_issue.status='resolved' THEN RETURN v_issue; END IF;

  UPDATE public.production_issues
  SET status='resolved',resolved_by=v_actor_id,resolved_at=now(),resolution_notes=btrim(p_resolution_notes)
  WHERE id=p_issue_id
  RETURNING * INTO v_issue;

  PERFORM public.append_operational_event_v1(
    p_event_type:='production_issue_resolved',
    p_entity_type:='production_issue',
    p_entity_id:=v_issue.id,
    p_title:='Production issue resolved: '||v_issue.issue_type||' ('||v_issue.department||')',
    p_source_application:='production',
    p_correlation_id:='resolve-'||p_issue_id::text,
    p_actor_id:=v_actor_id,
    p_actor_department:=v_issue.department,
    p_severity:='info',
    p_message:=btrim(p_resolution_notes),
    p_idempotency_key:='resolve-'||p_issue_id::text
  );

  RETURN v_issue;
END;
$$;

REVOKE ALL ON FUNCTION public.dispatch_production_to_rgs(uuid,numeric,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.report_production_issue(uuid,text,text,text,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.resolve_production_issue(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dispatch_production_to_rgs(uuid,numeric,text,text) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.report_production_issue(uuid,text,text,text,text,text) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.resolve_production_issue(uuid,text) TO authenticated,service_role;

-- D. B2B application review/delete authority (supersedes PR #389).
CREATE OR REPLACE FUNCTION public.enforce_b2b_application_review_authority_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path='pg_catalog','public','auth'
AS $$
DECLARE
  v_role text := upper(coalesce(public.get_user_role(auth.uid()),''));
  v_service boolean := current_user='service_role';
  v_review_mutation boolean := false;
BEGIN
  IF tg_op='DELETE' THEN
    IF NOT v_service AND v_role NOT IN ('ADMIN','SUPER_ADMIN') THEN
      RAISE EXCEPTION 'B2B_APPLICATION_ADMIN_REVIEW_REQUIRED' USING ERRCODE='42501';
    END IF;
    RETURN old;
  END IF;

  IF tg_op='UPDATE' THEN
    v_review_mutation :=
      new.status IS DISTINCT FROM old.status
      OR new.reviewed_by IS DISTINCT FROM old.reviewed_by
      OR new.reviewed_at IS DISTINCT FROM old.reviewed_at
      OR new.assigned_price_tier IS DISTINCT FROM old.assigned_price_tier
      OR new.rejection_reason IS DISTINCT FROM old.rejection_reason
      OR new.admin_notes IS DISTINCT FROM old.admin_notes
      OR new.requested_info_at IS DISTINCT FROM old.requested_info_at
      OR new.requested_info_note IS DISTINCT FROM old.requested_info_note
      OR new.resolved_company_id IS DISTINCT FROM old.resolved_company_id;

    IF v_review_mutation AND NOT v_service AND v_role NOT IN ('ADMIN','SUPER_ADMIN') THEN
      RAISE EXCEPTION 'B2B_APPLICATION_ADMIN_REVIEW_REQUIRED' USING ERRCODE='42501';
    END IF;
    RETURN new;
  END IF;

  RETURN coalesce(new,old);
END;
$$;

DROP TRIGGER IF EXISTS trg_b2b_application_review_authority_v1 ON public.b2b_applications;
CREATE TRIGGER trg_b2b_application_review_authority_v1
BEFORE UPDATE OR DELETE ON public.b2b_applications
FOR EACH ROW EXECUTE FUNCTION public.enforce_b2b_application_review_authority_v1();

DROP POLICY IF EXISTS "Staff delete applications" ON public.b2b_applications;
DROP POLICY IF EXISTS "Admins delete applications" ON public.b2b_applications;
CREATE POLICY "Admins delete applications"
ON public.b2b_applications
FOR DELETE TO authenticated
USING (
  public.is_internal_staff(auth.uid())
  AND upper(coalesce(public.get_user_role(auth.uid()),'')) IN ('ADMIN','SUPER_ADMIN')
);

REVOKE ALL ON FUNCTION public.enforce_b2b_application_review_authority_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_b2b_application_review_authority_v1() TO service_role;

-- E. Legacy rescue-payment verification/deletion authority (supersedes PR #390).
CREATE OR REPLACE FUNCTION public.guard_order_payment_authority_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog','public','auth'
AS $$
DECLARE
  v_role text := upper(coalesce(public.get_user_role(auth.uid()),''));
  v_finance_authority boolean := v_role IN ('FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER');
BEGIN
  IF auth.uid() IS NULL
     AND pg_catalog.pg_has_role(
       current_user,
       (SELECT pg_catalog.pg_get_userbyid(c.relowner)
        FROM pg_catalog.pg_class c
        WHERE c.oid='public.order_payments'::regclass),
       'USAGE'
     ) THEN
    RETURN CASE WHEN tg_op='DELETE' THEN old ELSE new END;
  END IF;

  IF tg_op='INSERT'
     AND new.idempotency_key IS NULL
     AND new.payment_type = 'rescue'
     AND new.status='uploaded'
     AND public.is_internal_staff(auth.uid()) THEN
    RETURN new;
  END IF;

  IF tg_op='UPDATE'
     AND old.idempotency_key IS NULL AND new.idempotency_key IS NULL
     AND old.payment_type = 'rescue' AND new.payment_type = 'rescue'
     AND old.status = 'uploaded' AND new.status IN ('uploaded','verified')
     AND v_finance_authority THEN
    RETURN new;
  END IF;

  IF tg_op='DELETE'
     AND old.idempotency_key IS NULL
     AND old.payment_type = 'rescue'
     AND v_finance_authority THEN
    RETURN old;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.order_payment_authority_scopes s
    WHERE s.backend_pid=pg_backend_pid()
      AND s.transaction_id=txid_current()
      AND (s.payment_id IS NULL OR s.payment_id=CASE WHEN tg_op='DELETE' THEN old.id ELSE new.id END)
  ) THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_AUTHORITY_REQUIRED' USING ERRCODE='42501';
  END IF;

  RETURN CASE WHEN tg_op='DELETE' THEN old ELSE new END;
END;
$$;

DROP POLICY IF EXISTS "Staff update legacy credit rescue payments" ON public.order_payments;
DROP POLICY IF EXISTS "Finance update legacy credit rescue payments" ON public.order_payments;
CREATE POLICY "Finance update legacy credit rescue payments"
ON public.order_payments
FOR UPDATE TO authenticated
USING (
  public.is_internal_staff(auth.uid())
  AND upper(coalesce(public.get_user_role(auth.uid()),'')) IN
      ('FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER')
  AND payment_type='rescue'
  AND idempotency_key IS NULL
)
WITH CHECK (
  public.is_internal_staff(auth.uid())
  AND upper(coalesce(public.get_user_role(auth.uid()),'')) IN
      ('FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER')
  AND payment_type='rescue'
  AND idempotency_key IS NULL
  AND status IN ('uploaded','verified')
);

DROP POLICY IF EXISTS "Staff delete legacy credit rescue payments" ON public.order_payments;
DROP POLICY IF EXISTS "Finance delete legacy credit rescue payments" ON public.order_payments;
CREATE POLICY "Finance delete legacy credit rescue payments"
ON public.order_payments
FOR DELETE TO authenticated
USING (
  public.is_internal_staff(auth.uid())
  AND upper(coalesce(public.get_user_role(auth.uid()),'')) IN
      ('FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER')
  AND payment_type='rescue'
  AND idempotency_key IS NULL
);

-- F. Buyer saved delivery-address write authority.
CREATE OR REPLACE FUNCTION public.customer_upsert_delivery_address_v1(
  p_address_id uuid,
  p_label text,
  p_street_address text,
  p_city text,
  p_state text,
  p_pincode text,
  p_contact_person text DEFAULT NULL,
  p_contact_phone text DEFAULT NULL,
  p_is_default boolean DEFAULT false
)
RETURNS TABLE(
  address_id uuid,label text,street_address text,city text,state text,pincode text,
  contact_person text,contact_phone text,is_default boolean,created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_company uuid;
  v_row public.delivery_addresses%rowtype;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_AUTH_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_company := public.customer_buyer_eligible_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_ELIGIBILITY_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF p_address_id IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_ID_REQUIRED' USING ERRCODE='22023';
  END IF;
  IF nullif(btrim(coalesce(p_label,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_street_address,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_city,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_state,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_pincode,'')),'') IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_REQUIRED_FIELDS' USING ERRCODE='22023';
  END IF;
  IF length(btrim(p_label))>80 OR length(btrim(p_street_address))>500
     OR length(btrim(p_city))>120 OR length(btrim(p_state))>120
     OR length(btrim(p_pincode))>20
     OR length(coalesce(btrim(p_contact_person),''))>120
     OR length(coalesce(btrim(p_contact_phone),''))>30 THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_FIELD_TOO_LONG' USING ERRCODE='22001';
  END IF;
  IF concat_ws('',p_label,p_street_address,p_city,p_state,p_pincode,p_contact_person,p_contact_phone) ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_CONTROL_CHAR_FORBIDDEN' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('buyer-address:'||v_company::text,0));

  IF coalesce(p_is_default,false) THEN
    UPDATE public.delivery_addresses
    SET is_default=false
    WHERE company_id=v_company OR (company_id IS NULL AND user_id=v_actor);
  END IF;

  INSERT INTO public.delivery_addresses(
    id,company_id,user_id,label,street_address,city,state,pincode,contact_person,contact_phone,is_default
  ) VALUES (
    p_address_id,v_company,v_actor,btrim(p_label),btrim(p_street_address),btrim(p_city),btrim(p_state),btrim(p_pincode),
    nullif(btrim(p_contact_person),''),nullif(btrim(p_contact_phone),''),coalesce(p_is_default,false)
  )
  ON CONFLICT (id) DO UPDATE SET
    company_id=excluded.company_id,
    user_id=excluded.user_id,
    label=excluded.label,
    street_address=excluded.street_address,
    city=excluded.city,
    state=excluded.state,
    pincode=excluded.pincode,
    contact_person=excluded.contact_person,
    contact_phone=excluded.contact_phone,
    is_default=excluded.is_default
  WHERE public.delivery_addresses.company_id=v_company
     OR (public.delivery_addresses.company_id IS NULL AND public.delivery_addresses.user_id=v_actor)
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_SCOPE_REQUIRED' USING ERRCODE='42501';
  END IF;

  RETURN QUERY SELECT
    v_row.id,v_row.label,v_row.street_address,v_row.city,v_row.state,v_row.pincode,
    nullif(btrim(v_row.contact_person),''),nullif(btrim(v_row.contact_phone),''),
    coalesce(v_row.is_default,false),v_row.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_delete_delivery_address_v1(p_address_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_company uuid;
  v_was_default boolean;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_AUTH_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_company := public.customer_buyer_eligible_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_ELIGIBILITY_REQUIRED' USING ERRCODE='42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('buyer-address:'||v_company::text,0));

  SELECT coalesce(is_default,false) INTO v_was_default
  FROM public.delivery_addresses
  WHERE id=p_address_id
    AND (company_id=v_company OR (company_id IS NULL AND user_id=v_actor))
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_ADDRESS_NOT_FOUND' USING ERRCODE='P0001';
  END IF;

  DELETE FROM public.delivery_addresses
  WHERE id=p_address_id
    AND (company_id=v_company OR (company_id IS NULL AND user_id=v_actor));

  IF coalesce(v_was_default,false)
     AND NOT EXISTS (
       SELECT 1 FROM public.delivery_addresses
       WHERE company_id=v_company AND coalesce(is_default,false)
     ) THEN
    UPDATE public.delivery_addresses da
    SET is_default=true
    WHERE da.id=(
      SELECT id FROM public.delivery_addresses
      WHERE company_id=v_company
      ORDER BY created_at DESC,id
      LIMIT 1
    );
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)
  FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.customer_delete_delivery_address_v1(uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)
  TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.customer_delete_delivery_address_v1(uuid)
  TO authenticated,service_role;

-- G. Multi-saved transporter master + Buyer authority.
CREATE TABLE IF NOT EXISTS public.customer_saved_transporters(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  transporter_name text NOT NULL,
  account_number text,
  is_default boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  CONSTRAINT customer_saved_transporters_name_nonempty CHECK (nullif(btrim(transporter_name),'') IS NOT NULL),
  CONSTRAINT customer_saved_transporters_name_len CHECK (length(transporter_name)<=120),
  CONSTRAINT customer_saved_transporters_account_len CHECK (account_number IS NULL OR length(account_number)<=120),
  CONSTRAINT customer_saved_transporters_default_active CHECK (NOT is_default OR is_active)
);

ALTER TABLE public.customer_saved_transporters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.customer_saved_transporters FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.customer_saved_transporters TO service_role;

CREATE INDEX IF NOT EXISTS customer_saved_transporters_company_idx
  ON public.customer_saved_transporters(company_id,is_active DESC,is_default DESC,updated_at DESC);

CREATE OR REPLACE FUNCTION public.customer_saved_transporters_v1()
RETURNS TABLE(
  transporter_id uuid,transporter_name text,account_number text,is_default boolean,is_active boolean,
  created_at timestamptz,updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  WITH eligible AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    t.id,t.transporter_name,nullif(btrim(t.account_number),''),
    t.is_default,t.is_active,t.created_at,t.updated_at
  FROM eligible e
  JOIN public.customer_saved_transporters t ON t.company_id=e.company_id
  WHERE e.company_id IS NOT NULL
  ORDER BY t.is_default DESC,t.is_active DESC,t.updated_at DESC,t.id;
$$;

CREATE OR REPLACE FUNCTION public.customer_upsert_saved_transporter_v1(
  p_transporter_id uuid,
  p_transporter_name text,
  p_account_number text DEFAULT NULL,
  p_is_default boolean DEFAULT false,
  p_is_active boolean DEFAULT true
)
RETURNS TABLE(
  transporter_id uuid,transporter_name text,account_number text,is_default boolean,is_active boolean,
  created_at timestamptz,updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_company uuid;
  v_row public.customer_saved_transporters%rowtype;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_AUTH_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_company := public.customer_buyer_eligible_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_ELIGIBILITY_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF p_transporter_id IS NULL OR nullif(btrim(coalesce(p_transporter_name,'')),'') IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_REQUIRED_FIELDS' USING ERRCODE='22023';
  END IF;
  IF length(btrim(p_transporter_name))>120
     OR length(coalesce(btrim(p_account_number),''))>120 THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_FIELD_TOO_LONG' USING ERRCODE='22001';
  END IF;
  IF concat_ws('',p_transporter_name,p_account_number) ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_CONTROL_CHAR_FORBIDDEN' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('buyer-transporter:'||v_company::text,0));

  IF coalesce(p_is_default,false) AND coalesce(p_is_active,true) THEN
    UPDATE public.customer_saved_transporters AS t
    SET is_default=false,updated_at=statement_timestamp()
    WHERE t.company_id=v_company AND t.is_default;
  END IF;

  INSERT INTO public.customer_saved_transporters(
    id,company_id,transporter_name,account_number,is_default,is_active,created_by
  ) VALUES (
    p_transporter_id,v_company,btrim(p_transporter_name),nullif(btrim(p_account_number),''),
    (coalesce(p_is_default,false) AND coalesce(p_is_active,true)),coalesce(p_is_active,true),v_actor
  )
  ON CONFLICT (id) DO UPDATE SET
    transporter_name=excluded.transporter_name,
    account_number=excluded.account_number,
    is_default=excluded.is_default,
    is_active=excluded.is_active,
    updated_at=statement_timestamp()
  WHERE public.customer_saved_transporters.company_id=v_company
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_SCOPE_REQUIRED' USING ERRCODE='42501';
  END IF;

  UPDATE public.companies AS c
  SET (preferred_courier,courier_account_number)=(
    SELECT t.transporter_name,t.account_number
    FROM public.customer_saved_transporters AS t
    WHERE t.company_id=v_company
      AND t.is_default
      AND t.is_active
    ORDER BY t.updated_at DESC,t.id
    LIMIT 1
  )
  WHERE c.id=v_company;

  RETURN QUERY SELECT
    v_row.id,v_row.transporter_name,nullif(btrim(v_row.account_number),''),
    v_row.is_default,v_row.is_active,v_row.created_at,v_row.updated_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_delete_saved_transporter_v1(p_transporter_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_company uuid;
  v_row public.customer_saved_transporters%rowtype;
  v_replacement public.customer_saved_transporters%rowtype;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_AUTH_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_company := public.customer_buyer_eligible_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_ELIGIBILITY_REQUIRED' USING ERRCODE='42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('buyer-transporter:'||v_company::text,0));

  SELECT * INTO v_row
  FROM public.customer_saved_transporters
  WHERE id=p_transporter_id AND company_id=v_company
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_TRANSPORTER_NOT_FOUND' USING ERRCODE='P0001';
  END IF;

  DELETE FROM public.customer_saved_transporters
  WHERE id=p_transporter_id AND company_id=v_company;

  IF v_row.is_default THEN
    SELECT t.* INTO v_replacement
    FROM public.customer_saved_transporters AS t
    WHERE t.company_id=v_company AND t.is_active
    ORDER BY t.updated_at DESC,t.id
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      UPDATE public.customer_saved_transporters AS t
      SET is_default=(t.id=v_replacement.id),
          updated_at=CASE WHEN t.id=v_replacement.id THEN statement_timestamp() ELSE t.updated_at END
      WHERE t.company_id=v_company;

      UPDATE public.companies
      SET preferred_courier=v_replacement.transporter_name,
          courier_account_number=v_replacement.account_number
      WHERE id=v_company;
    ELSE
      UPDATE public.companies
      SET preferred_courier=NULL,courier_account_number=NULL
      WHERE id=v_company;
    END IF;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_saved_transporters_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.customer_delete_saved_transporter_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.customer_saved_transporters_v1() TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean)
  TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.customer_delete_saved_transporter_v1(uuid)
  TO authenticated,service_role;

-- H. Server-only payment-provider adapter helpers.
CREATE OR REPLACE FUNCTION public.record_payment_gateway_verified_provider_event_v1(
  p_intent_id uuid,
  p_event_type text,
  p_provider_event_id text,
  p_provider_payment_id text,
  p_provider_amount numeric,
  p_provider_currency text,
  p_payload jsonb,
  p_correlation_id text,
  p_idempotency_key text,
  p_provider_order_id text DEFAULT NULL
)
RETURNS TABLE(provider_event_id uuid,already_recorded boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth,extensions
AS $$
DECLARE
  v_hash text;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_VERIFIED_EVENT_SERVICE_ONLY' USING ERRCODE='42501';
  END IF;
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PROVIDER_PAYLOAD_OBJECT_REQUIRED' USING ERRCODE='22023';
  END IF;

  v_hash := encode(extensions.digest(p_payload::text,'sha256'),'hex');

  RETURN QUERY
  SELECT *
  FROM public.record_payment_gateway_provider_event_v1(
    p_intent_id,p_event_type,p_provider_event_id,p_provider_payment_id,p_provider_amount,
    p_provider_currency,p_payload,v_hash,true,p_correlation_id,p_idempotency_key,p_provider_order_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_payment_gateway_intent_by_provider_order_v1(p_provider_order_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $$
DECLARE
  v_intent public.payment_gateway_payable_intents%rowtype;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PROVIDER_LOOKUP_SERVICE_ONLY' USING ERRCODE='42501';
  END IF;
  IF nullif(btrim(coalesce(p_provider_order_id,'')),'') IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PROVIDER_ORDER_REQUIRED' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_intent
  FROM public.payment_gateway_payable_intents
  WHERE provider_order_id=btrim(p_provider_order_id)
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PROVIDER_ORDER_NOT_FOUND' USING ERRCODE='P0001';
  END IF;

  RETURN jsonb_build_object(
    'intent_id',v_intent.id,
    'order_id',v_intent.order_id,
    'company_id',v_intent.company_id,
    'provider_code',v_intent.provider_code,
    'canonical_amount',v_intent.canonical_amount,
    'currency',v_intent.currency,
    'status',v_intent.status,
    'provider_order_id',v_intent.provider_order_id,
    'expires_at',v_intent.expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_payment_gateway_verified_provider_event_v1(
  uuid,text,text,text,numeric,text,jsonb,text,text,text
) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.get_payment_gateway_intent_by_provider_order_v1(text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_payment_gateway_verified_provider_event_v1(
  uuid,text,text,text,numeric,text,jsonb,text,text,text
) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_payment_gateway_intent_by_provider_order_v1(text)
  TO service_role;


-- I. Provider-agnostic payment runtime configuration.
-- This table contains only non-secret adapter metadata. No provider row is
-- seeded by this migration: runtime remains fail-closed until engineering
-- deliberately configures one adapter. The outbound provider endpoint is
-- engineering-controlled Edge Runtime configuration and is never database-
-- controlled. Merchant credentials live only in Supabase Edge Function secrets.
CREATE TABLE public.payment_gateway_provider_config (
  config_key text PRIMARY KEY DEFAULT 'primary',
  adapter_code text NOT NULL,
  provider_code text NOT NULL DEFAULT 'generic',
  webhook_signature_header text NOT NULL DEFAULT 'x-payment-signature',
  is_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  CONSTRAINT payment_gateway_provider_config_singleton CHECK (config_key = 'primary'),
  CONSTRAINT payment_gateway_provider_config_adapter CHECK (
    adapter_code IN ('merchant_salt_hmac_json_v1')
  ),
  CONSTRAINT payment_gateway_provider_config_provider_code CHECK (
    provider_code = 'generic'
  ),
  CONSTRAINT payment_gateway_provider_config_signature_header CHECK (
    webhook_signature_header ~ '^[A-Za-z0-9-]+$'
  )
);

ALTER TABLE public.payment_gateway_provider_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.payment_gateway_provider_config FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.payment_gateway_provider_config TO service_role;

CREATE OR REPLACE FUNCTION public.get_payment_gateway_provider_config_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_config public.payment_gateway_provider_config%rowtype;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PROVIDER_CONFIG_SERVICE_ONLY' USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_config
  FROM public.payment_gateway_provider_config
  WHERE config_key='primary' AND is_enabled
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'adapter_code',v_config.adapter_code,
    'provider_code',v_config.provider_code,
    'webhook_signature_header',v_config.webhook_signature_header,
    'is_enabled',v_config.is_enabled
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_payment_gateway_provider_config_v1()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_payment_gateway_provider_config_v1()
  TO service_role;

COMMENT ON TABLE public.payment_gateway_provider_config IS
  'Non-secret provider adapter selector metadata only; outbound URL is controlled by Edge Runtime configuration. Empty table means payment provider runtime is inactive.';
COMMENT ON FUNCTION public.get_payment_gateway_provider_config_v1() IS
  'Service-role-only provider-neutral payment adapter configuration lookup.';
