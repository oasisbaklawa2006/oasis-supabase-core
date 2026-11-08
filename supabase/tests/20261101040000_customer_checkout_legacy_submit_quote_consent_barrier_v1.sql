-- Behavioral + PostgREST-equivalent ACL contract for migration
-- 20261101040000_customer_checkout_legacy_submit_quote_consent_barrier_v1.sql
BEGIN;
SELECT plan(10);

SELECT function_privs_are(
  'public', 'submit_customer_order_v1', ARRAY['text', 'date']::text[],
  'authenticated', ARRAY[]::text[],
  'authenticated cannot execute legacy direct checkout submit (PostgREST RPC boundary)'
);

SELECT function_privs_are(
  'public', 'submit_customer_order_v1', ARRAY['text', 'date']::text[],
  'service_role', ARRAY['EXECUTE']::text[],
  'service_role retains legacy writer execute for privileged paths'
);

SELECT ok(
  NOT has_function_privilege('public', 'public.submit_customer_order_v1(text,date)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.submit_customer_order_v1(text,date)', 'EXECUTE'),
  'PUBLIC/anon cannot inherit legacy checkout writer EXECUTE'
);

SELECT function_privs_are(
  'public', 'submit_customer_order_quoted_v1', ARRAY['text', 'text', 'date']::text[],
  'authenticated', ARRAY['EXECUTE']::text[],
  'authenticated buyer checkout submit remains quoted-only'
);

SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$SELECT * FROM public.submit_customer_order_v1('consent-deny-key', NULL)$$,
  'permission denied for function submit_customer_order_v1',
  'authenticated PostgREST-equivalent role cannot call legacy submit RPC'
);

RESET ROLE;

DO $$
DECLARE
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_product uuid;
  v_quote jsonb;
  v_fp text;
  v_order_id uuid;
  v_dup boolean;
  v_so numeric;
  v_advance numeric;
BEGIN
  SET LOCAL session_replication_role = replica;

  INSERT INTO public.companies (business_name, status) VALUES ('Quote Consent Co', 'active') RETURNING id INTO v_company;
  INSERT INTO auth.users (id, email) VALUES (v_buyer, 'quote-consent@example.test');
  INSERT INTO public.users (id, email, role, company_id)
  VALUES (v_buyer, 'quote-consent@example.test', 'b2b_buyer', v_company);
  INSERT INTO public.profiles (id, company_id, role, is_approved, status, email)
  VALUES (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'quote-consent@example.test');

  INSERT INTO public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price, price_b2b
  ) VALUES (
    'QCONS-SKU', 'Quote Consent Product', 'Quote Consent Product', 'Bakery', '19059090',
    true, true, true, 2, 2, 250, 250
  ) RETURNING id INTO v_product;

  INSERT INTO public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) VALUES (v_product, 'b2b', 'approved', 250, 250, 'INR', 'kg', 18, false);

  INSERT INTO public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  VALUES (v_product, 'b2b', true, 2, 2, 2);

  SET LOCAL session_replication_role = default;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM public.add_customer_order_draft_line_v1(v_product, 2);

  v_quote := public.customer_checkout_quote_v1();
  v_fp := v_quote->>'fingerprint';

  SELECT order_id, sales_order_value, advance_required, is_duplicate_submission
    INTO v_order_id, v_so, v_advance, v_dup
    FROM public.submit_customer_order_quoted_v1('consent-quoted-key', v_fp, current_date);

  IF v_order_id IS NULL OR v_dup THEN
    RAISE EXCEPTION 'REGRESSION: quoted first submit failed';
  END IF;

  IF v_so IS DISTINCT FROM (v_quote->>'sales_order_value')::numeric
     OR v_advance IS DISTINCT FROM (v_quote->>'advance_required')::numeric THEN
    RAISE EXCEPTION 'REGRESSION: quoted submit financials diverged from approved quote';
  END IF;

  SELECT is_duplicate_submission INTO v_dup
    FROM public.submit_customer_order_quoted_v1('consent-quoted-key', v_fp, current_date);
  IF NOT v_dup THEN
    RAISE EXCEPTION 'REGRESSION: quoted idempotent replay did not report duplicate';
  END IF;

  IF (SELECT count(*) FROM public.orders WHERE company_id = v_company AND checkout_idempotency_key = 'consent-quoted-key') <> 1 THEN
    RAISE EXCEPTION 'REGRESSION: duplicate quoted retries created multiple orders';
  END IF;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims', NULL, true);
END $$;

SELECT pass('quoted authenticated checkout binds exactly one order with approved tax-inclusive totals');

DO $$
DECLARE
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_product uuid;
  v_quote jsonb;
  v_fp text;
BEGIN
  SET LOCAL session_replication_role = replica;

  INSERT INTO public.companies (business_name, status) VALUES ('Quote Consent Bad FP Co', 'active') RETURNING id INTO v_company;
  INSERT INTO auth.users (id, email) VALUES (v_buyer, 'quote-badfp@example.test');
  INSERT INTO public.users (id, email, role, company_id)
  VALUES (v_buyer, 'quote-badfp@example.test', 'b2b_buyer', v_company);
  INSERT INTO public.profiles (id, company_id, role, is_approved, status, email)
  VALUES (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'quote-badfp@example.test');

  INSERT INTO public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price, price_b2b
  ) VALUES (
    'QCONS-BAD', 'Bad FP Product', 'Bad FP Product', 'Bakery', '19059090',
    true, true, true, 1, 1, 100, 100
  ) RETURNING id INTO v_product;

  INSERT INTO public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) VALUES (v_product, 'b2b', 'approved', 100, 100, 'INR', 'kg', 0, true);

  INSERT INTO public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  VALUES (v_product, 'b2b', true, 1, 1, 1);

  SET LOCAL session_replication_role = default;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM public.add_customer_order_draft_line_v1(v_product, 1);

  BEGIN
    PERFORM * FROM public.submit_customer_order_quoted_v1('bad-fp-key', '00000000000000000000000000000000', NULL);
    RAISE EXCEPTION 'REGRESSION: bad fingerprint accepted';
  EXCEPTION WHEN sqlstate '22023' THEN
    NULL;
  END;

  IF (SELECT count(*) FROM public.orders WHERE company_id = v_company) <> 0 THEN
    RAISE EXCEPTION 'REGRESSION: bad fingerprint path created an order';
  END IF;

  v_quote := public.customer_checkout_quote_v1();
  v_fp := v_quote->>'fingerprint';

  RESET ROLE;
  UPDATE public.product_pricing_rules SET calculated_price = 999, base_price = 999 WHERE product_id = v_product;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  BEGIN
    PERFORM * FROM public.submit_customer_order_quoted_v1('stale-fp-key', v_fp, NULL);
    RAISE EXCEPTION 'REGRESSION: stale fingerprint after price change accepted';
  EXCEPTION WHEN sqlstate '22023' THEN
    NULL;
  END;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims', NULL, true);
END $$;

SELECT pass('wrong and stale quote fingerprints fail closed without order side effects');

SELECT ok(
  pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure)
    LIKE '%submit_customer_order_v1(%',
  'quoted wrapper still delegates to canonical writer under SECURITY DEFINER'
);

SELECT ok(
  NOT pg_get_functiondef('public.submit_customer_order_v1(text,date)'::regprocedure) ILIKE '%fingerprint%'
  AND NOT pg_get_functiondef('public.submit_customer_order_v1(text,date)'::regprocedure) ILIKE '%quote%',
  'legacy writer body unchanged: consent enforcement remains in quoted wrapper + EXECUTE boundary'
);

SELECT ok(
  has_function_privilege('service_role', 'public.submit_customer_order_v1(text,date)', 'EXECUTE'),
  'privileged service_role EXECUTE retained on canonical writer'
);

SELECT * FROM finish();
ROLLBACK;
