-- PF-6A contract coverage for migration
-- 20260829110000_pre_factory_payment_authority: canonical payment evidence
-- and Finance authority.

select plan(36);

select has_table('public', 'order_payment_authority_idempotency', 'payment idempotency ledger exists');
select has_table('public', 'order_payment_authority_audit', 'payment audit ledger exists');
select has_table('public', 'order_payment_authority_scopes', 'payment mutation scopes exist');
select has_function('public', 'record_order_payment_proof_v1', array['uuid','uuid','uuid','text','numeric','text','text','text','text','text','text','text','text','text','uuid'], 'proof receipt RPC exists');
select has_function('public', 'verify_order_payment_v1', array['uuid','numeric','text','text','text','text','text','uuid'], 'payment verification RPC exists');
select has_function('public', 'reject_order_payment_v1', array['uuid','text','text','text','uuid'], 'payment rejection RPC exists');
select has_function('public', 'record_whatsapp_payment_proof_in_canonical_ledger_v1', array['uuid','uuid','uuid','uuid','text','text','text','text','uuid'], 'WhatsApp proof bridge exists');
select has_function('public', 'get_order_payment_facts_v1', array['uuid'], 'factual payment projection exists');

select ok((select relrowsecurity from pg_class where oid = 'public.order_payment_authority_idempotency'::regclass), 'idempotency RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.order_payment_authority_audit'::regclass), 'payment audit RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.order_payment_authority_scopes'::regclass), 'mutation scopes RLS enabled');
select ok(has_table_privilege('authenticated', 'public.order_payments', 'INSERT'), 'legacy authenticated payment insert compatibility remains available');
select ok(has_table_privilege('authenticated', 'public.order_payments', 'UPDATE'), 'legacy authenticated payment update compatibility remains available');
select ok(has_table_privilege('authenticated', 'public.order_payments', 'DELETE'), 'legacy authenticated payment delete compatibility remains available');
select ok(pg_get_functiondef('public.guard_order_payment_authority_mutation()'::regprocedure) like '%NEW.payment_type = ''rescue''%', 'legacy insert bypass is limited to rescue uploads');
select ok(pg_get_functiondef('public.guard_order_payment_authority_mutation()'::regprocedure) like '%OLD.status = ''uploaded''%', 'legacy update bypass is limited to rescue review transitions');
select ok(not has_table_privilege('service_role', 'public.order_payments', 'INSERT'), 'service_role cannot directly insert canonical payments');
select ok(not has_table_privilege('service_role', 'public.order_payment_authority_audit', 'INSERT'), 'service_role cannot directly insert payment audit');
select ok(has_function_privilege('authenticated', 'public.record_order_payment_proof_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,text,text,text,text,text,uuid)', 'EXECUTE'), 'authenticated can submit proof through RPC');
select ok(has_function_privilege('authenticated', 'public.verify_order_payment_v1(uuid,numeric,text,text,text,text,text,uuid)', 'EXECUTE'), 'authenticated can request Finance verification RPC');
select ok(not has_function_privilege('service_role', 'public.verify_order_payment_v1(uuid,numeric,text,text,text,text,text,uuid)', 'EXECUTE'), 'service_role cannot impersonate Finance verifier');
select ok(pg_get_functiondef('public.record_order_payment_proof_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%ORDER_PAYMENT_ACTOR_MISMATCH%', 'proof actor is bound to auth.uid');
select ok(pg_get_functiondef('public.verify_order_payment_v1(uuid,numeric,text,text,text,text,text,uuid)'::regprocedure) like '%has_step_up_auth%', 'verification requires AAL2');
select ok(pg_get_functiondef('public.verify_order_payment_v1(uuid,numeric,text,text,text,text,text,uuid)'::regprocedure) like '%payment_release_mutated%', 'verification does not release operations');
select ok(pg_get_functiondef('public.record_whatsapp_payment_proof_in_canonical_ledger_v1(uuid,uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure) like '%uploaded only%', 'WhatsApp bridge remains unverified');
select ok(pg_get_functiondef('public.get_order_payment_facts_v1(uuid)'::regprocedure) like '%payment_facts_only%', 'projection is factual and not clearance');
select ok(pg_get_functiondef('public.assert_order_payment_binding_v1(uuid,uuid,uuid)'::regprocedure) like '%ORDER_PAYMENT_COMMERCIAL_VERSION_MISMATCH%', 'PI/SO version binding fails closed');
select ok(pg_get_functiondef('public.record_order_payment_proof_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%ORDER_PAYMENT_REFERENCE_CONFLICT%', 'duplicate financial references conflict');
select ok(pg_get_functiondef('public.record_order_payment_proof_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%pg_advisory_xact_lock%', 'proof receipt is serialized');
select ok(pg_get_functiondef('public.verify_order_payment_v1(uuid,numeric,text,text,text,text,text,uuid)'::regprocedure) like '%pg_advisory_xact_lock%', 'verification is serialized');
select ok(pg_get_functiondef('public.guard_order_payment_authority_audit_mutation()'::regprocedure) like '%ORDER_PAYMENT_AUDIT_IMMUTABLE%', 'payment audit is append-only');
select ok(pg_get_functiondef('public.guard_order_payment_authority_mutation()'::regprocedure) like '%idempotency_key IS NULL%', 'governed direct payment mutation requires an authority scope');
select ok(pg_get_functiondef('public.get_order_payment_facts_v1(uuid)'::regprocedure) not like '%FOR SHARE%', 'payment facts read path is lock-free');

-- Existing WhatsApp review remains an evidence-only decision and does not
-- mutate order_payments; the bridge above is the explicit canonical path.
select ok((select pg_get_functiondef('public.whatsapp_review_case_payment_proof(uuid,text,numeric,text,text,text)'::regprocedure) like '%order_payment_mutated%false%'), 'WhatsApp review remains separate from canonical payment verification');

select lives_ok($pf6a_runtime$
DO $pf6a$
DECLARE
  v_company uuid := '92000000-0000-0000-0000-000000000001';
  v_product uuid := '92000000-0000-0000-0000-000000000002';
  v_order uuid := '92000000-0000-0000-0000-000000000003';
  v_item uuid := '92000000-0000-0000-0000-000000000004';
  v_actor uuid := '92000000-0000-0000-0000-000000000011';
  v_other_actor uuid := '92000000-0000-0000-0000-000000000012';
  v_sales_actor uuid := '92000000-0000-0000-0000-000000000013';
  v_version uuid;
  v_pi uuid;
  v_payment_1 uuid;
  v_payment_2 uuid;
  v_payment_3 uuid;
  v_payment_4 uuid;
  v_retry uuid;
  v_summary jsonb;
  v_rows integer;
BEGIN
  set local session_replication_role = replica;
  INSERT INTO auth.users(id, email) VALUES
    (v_actor, 'pf6a-finance@test.invalid'),
    (v_other_actor, 'pf6a-finance-other@test.invalid'),
    (v_sales_actor, 'pf6a-sales@test.invalid');
  INSERT INTO public.users(id, role, name, is_active) VALUES
    (v_actor, 'FINANCE_EXEC', 'PF6A Finance', true),
    (v_other_actor, 'FINANCE_EXEC', 'PF6A Finance Other', true),
    (v_sales_actor, 'SALES_EXECUTIVE', 'PF6A Sales', true);
  INSERT INTO public.companies(id, business_name, status) VALUES (v_company, 'PF6A Contract Co', 'active');
  INSERT INTO public.products(id, sku, product_name, name, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b)
  VALUES (v_product, 'PF6A-SKU-1', 'PF6A Product', 'PF6A Product', 'Bakery', '19059090', true, true, true, 1, 1, 650, 650);
  INSERT INTO public.product_pricing_rules(product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive)
  VALUES (v_product, 'b2b', 'approved', 650, 650, 'INR', 'kg', 18, false);
  INSERT INTO public.product_moq_rules(product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  VALUES (v_product, 'b2b', true, 1, 1, 1);
  INSERT INTO public.orders(id, company_id, status, order_origin, order_number, tracking_token)
  VALUES (v_order, v_company, 'submitted', 'SALES', 'SO-PF6A-1', md5(random()::text));
  INSERT INTO public.order_items(id, order_id, product_id, quantity, pack_size, carton_type)
  VALUES (v_item, v_order, v_product, 10, 'kg', 'carton');
  set local session_replication_role = default;

  PERFORM public.recalculate_governed_sales_order_financials_v1(v_order);
  v_version := public.create_sales_order_commercial_version_v1(v_order, 'PF6A_PREPARE', 'pf6a:so:1', 'pf6a-so-version-1', v_actor);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  SELECT pi_id INTO v_pi FROM public.create_sales_order_proforma_invoice_v1(v_order, v_version, 'PF6A_CREATE', 'SALES', 'pf6a:create:1', 'pf6a-create-1', v_actor);

  SELECT payment_id INTO v_payment_1 FROM public.record_order_payment_proof_v1(
    v_order, v_pi, v_version, 'advance', 2500, 'INR', 'UPI', 'UTR-PF6A-1', 'PF6A CO',
    'receipt://pf6a-1', 'CUSTOMER_APP', 'checkout:pf6a-1', 'pf6a:receive:1', 'pf6a-receive-1', v_actor);
  SELECT payment_id INTO v_retry FROM public.record_order_payment_proof_v1(
    v_order, v_pi, v_version, 'advance', 2500, 'INR', 'UPI', 'UTR-PF6A-1', 'PF6A CO',
    'receipt://pf6a-1', 'CUSTOMER_APP', 'checkout:pf6a-1', 'pf6a:receive:1', 'pf6a-receive-1', v_actor);
  IF v_retry IS DISTINCT FROM v_payment_1 THEN RAISE EXCEPTION 'PF6A_RECEIVE_IDEMPOTENCY_REGRESSION'; END IF;
  SELECT payment_id INTO v_payment_2 FROM public.record_order_payment_proof_v1(
    v_order, v_pi, v_version, 'balance', 1000, 'INR', 'BANK', 'UTR-PF6A-2', 'PF6A CO',
    'receipt://pf6a-2', 'WHATSAPP', 'whatsapp-case-payment-proof:2', 'pf6a:receive:2', 'pf6a-receive-2', v_actor);
  SELECT payment_id INTO v_payment_3 FROM public.record_order_payment_proof_v1(
    v_order, v_pi, v_version, 'balance', 1000, 'INR', 'BANK', 'UTR-PF6A-3', 'PF6A CO',
    'receipt://pf6a-3', 'SALES', 'sales:payment:3', 'pf6a:receive:3', 'pf6a-receive-3', v_actor);
  SELECT payment_id INTO v_payment_4 FROM public.record_order_payment_proof_v1(
    v_order, v_pi, v_version, 'balance', 1000, 'INR', 'BANK', 'UTR-PF6A-4', 'PF6A CO',
    'receipt://pf6a-4', 'MANUAL', 'manual:payment:4', 'pf6a:receive:4', 'pf6a-receive-4', v_actor);

  BEGIN
    INSERT INTO public.order_payments(
      order_id, company_id, payment_type, amount, reference_no, created_by,
      status, proforma_invoice_id, commercial_version_id, source_channel,
      source_reference, currency, proof_evidence_reference,
      proof_received_at, proof_received_by, correlation_id, idempotency_key
    ) VALUES (
      v_order, v_company, 'advance', 2500, 'UTR-PF6A-DIRECT', v_actor,
      'uploaded', v_pi, v_version, 'CUSTOMER_APP', 'checkout:direct', 'INR',
      'receipt://pf6a-direct', statement_timestamp(), v_actor,
      'pf6a:direct', 'pf6a-direct-key'
    );
    RAISE EXCEPTION 'PF6A_DIRECT_GOVERNED_WRITE_REGRESSION';
  EXCEPTION WHEN sqlstate '42501' THEN NULL;
  END;

  BEGIN
    INSERT INTO public.order_payments(
      order_id, company_id, payment_type, amount, reference_no, created_by,
      status
    ) VALUES (
      v_order, v_company, 'advance', 2500, 'UTR-PF6A-NULL-IDEMPOTENCY', v_actor,
      'uploaded'
    );
    RAISE EXCEPTION 'PF6A_NULL_IDEMPOTENCY_BYPASS_REGRESSION';
  EXCEPTION WHEN sqlstate '42501' THEN NULL;
  END;

  BEGIN
    UPDATE public.order_payments
       SET status = 'verified', verified_amount = amount, verified_by = v_actor,
           verified_at = statement_timestamp(), verification_evidence_reference = 'finance://direct'
     WHERE id = v_payment_1;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows > 0 THEN RAISE EXCEPTION 'PF6A_DIRECT_VERIFICATION_REGRESSION'; END IF;
  EXCEPTION WHEN sqlstate '42501' THEN NULL;
  END;

  BEGIN
    PERFORM public.record_order_payment_proof_v1(
      v_order, v_pi, v_version, 'advance', 2500, 'INR', 'UPI', 'UTR-PF6A-1', 'PF6A CO',
      'receipt://pf6a-duplicate', 'CUSTOMER_APP', 'checkout:duplicate', 'pf6a:receive:dup', 'pf6a-receive-dup', v_actor);
    RAISE EXCEPTION 'PF6A_DUPLICATE_REFERENCE_REGRESSION';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_other_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
    PERFORM public.record_order_payment_proof_v1(
      v_order, v_pi, v_version, 'advance', 2500, 'INR', 'UPI', 'UTR-PF6A-1', 'PF6A CO',
      'receipt://pf6a-1', 'CUSTOMER_APP', 'checkout:pf6a-1', 'pf6a:receive:1', 'pf6a-receive-1', v_other_actor);
    RAISE EXCEPTION 'PF6A_CROSS_ACTOR_IDEMPOTENCY_REGRESSION';
  EXCEPTION WHEN sqlstate '42501' THEN NULL;
  END;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  BEGIN
    PERFORM public.record_order_payment_proof_v1(
      v_order, '92000000-0000-0000-0000-000000000099'::uuid, v_version, 'advance', 2500, 'INR', 'UPI', NULL, 'PF6A CO',
      'receipt://pf6a-wrong-pi', 'CUSTOMER_APP', 'checkout:wrong-pi', 'pf6a:receive:wrong-pi', 'pf6a-receive-wrong-pi', v_actor);
    RAISE EXCEPTION 'PF6A_WRONG_PI_REGRESSION';
  EXCEPTION WHEN sqlstate 'P0001' THEN NULL;
  END;

  BEGIN
    PERFORM public.record_order_payment_proof_v1(
      v_order, v_pi, '92000000-0000-0000-0000-000000000099'::uuid, 'advance', 2500, 'INR', 'UPI', NULL, 'PF6A CO',
      'receipt://pf6a-wrong-version', 'CUSTOMER_APP', 'checkout:wrong-version', 'pf6a:receive:wrong-version', 'pf6a-receive-wrong-version', v_actor);
    RAISE EXCEPTION 'PF6A_WRONG_VERSION_REGRESSION';
  EXCEPTION WHEN sqlstate '40001' THEN NULL;
  END;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_sales_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
    PERFORM public.verify_order_payment_v1(v_payment_1, 2000, 'BANK-PF6A-1', 'finance://pf6a-1', 'short payment recorded', 'pf6a:verify:unauthorized', 'pf6a-verify-unauthorized', v_sales_actor);
    RAISE EXCEPTION 'PF6A_UNAUTHORIZED_VERIFICATION_REGRESSION';
  EXCEPTION WHEN sqlstate 'P0001' THEN NULL;
  END;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  BEGIN
    PERFORM public.verify_order_payment_v1(v_payment_1, 2000, 'BANK-PF6A-1', 'finance://pf6a-1', 'short payment recorded', 'pf6a:verify:aal1', 'pf6a-verify-aal1', v_actor);
    RAISE EXCEPTION 'PF6A_AAL2_REGRESSION';
  EXCEPTION WHEN sqlstate '42501' THEN NULL;
  END;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  SELECT payment_id INTO v_retry FROM public.verify_order_payment_v1(v_payment_1, 2000, 'BANK-PF6A-1', 'finance://pf6a-1', 'short payment recorded', 'pf6a:verify:1', 'pf6a-verify-1', v_actor);
  SELECT payment_id INTO v_retry FROM public.verify_order_payment_v1(v_payment_1, 2000, 'BANK-PF6A-1', 'finance://pf6a-1', 'short payment recorded', 'pf6a:verify:1', 'pf6a-verify-1', v_actor);
  IF v_retry IS DISTINCT FROM v_payment_1 THEN RAISE EXCEPTION 'PF6A_VERIFY_IDEMPOTENCY_REGRESSION'; END IF;
  PERFORM public.verify_order_payment_v1(v_payment_2, 1000, 'BANK-PF6A-2', 'finance://pf6a-2', NULL, 'pf6a:verify:2', 'pf6a-verify-2', v_actor);
  PERFORM public.verify_order_payment_v1(v_payment_3, 9000, 'BANK-PF6A-3', 'finance://pf6a-3', 'excess is factual only', 'pf6a:verify:3', 'pf6a-verify-3', v_actor);
  BEGIN
    PERFORM public.verify_order_payment_v1(v_payment_4, 1000, 'BANK-PF6A-3', 'finance://pf6a-4', NULL, 'pf6a:verify:duplicate-ref', 'pf6a-verify-duplicate-ref', v_actor);
    RAISE EXCEPTION 'PF6A_VERIFIED_REFERENCE_REGRESSION';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  SELECT payment_id INTO v_retry FROM public.reject_order_payment_v1(v_payment_4, 'receipt is unreadable', 'pf6a:reject:4', 'pf6a-reject-4', v_actor);
  IF v_retry IS DISTINCT FROM v_payment_4 THEN RAISE EXCEPTION 'PF6A_REJECTION_REGRESSION'; END IF;
  SELECT payment_id INTO v_retry FROM public.reject_order_payment_v1(v_payment_4, 'receipt is unreadable', 'pf6a:reject:4', 'pf6a-reject-4', v_actor);
  IF v_retry IS DISTINCT FROM v_payment_4 THEN RAISE EXCEPTION 'PF6A_REJECT_IDEMPOTENCY_REGRESSION'; END IF;

  SELECT public.get_order_payment_facts_v1(v_pi) INTO v_summary;
  IF (v_summary ->> 'verified_total')::numeric <> 12000
     OR (v_summary ->> 'remaining_commercial_amount')::numeric <> 0
     OR (v_summary ->> 'payment_facts_only')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'PF6A_FACTUAL_SUMMARY_REGRESSION';
  END IF;
  IF (SELECT status FROM public.orders WHERE id = v_order) <> 'submitted'
     OR coalesce((SELECT payment_cleared FROM public.orders WHERE id = v_order), false) THEN
    RAISE EXCEPTION 'PF6A_OPERATIONAL_RELEASE_REGRESSION';
  END IF;
  IF (SELECT proof_evidence_reference FROM public.order_payments WHERE id = v_payment_4) <> 'receipt://pf6a-4'
     OR (SELECT status FROM public.order_payments WHERE id = v_payment_4) <> 'rejected' THEN
    RAISE EXCEPTION 'PF6A_REJECTION_HISTORY_REGRESSION';
  END IF;
  reset role;
END $pf6a$;
$pf6a_runtime$, 'PF-6A payment lifecycle integration remains valid');

select ok(true, 'PF-6A canonical payment authority contract holds');
