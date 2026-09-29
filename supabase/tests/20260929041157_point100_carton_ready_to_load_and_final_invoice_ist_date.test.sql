begin;
-- Runtime coverage for 20260929041157_point100_carton_ready_to_load_and_final_invoice_ist_date.sql
select plan(25);

select has_function(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  array['uuid', 'integer', 'text'],
  'ready-to-load RPC exists'
);

select ok(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure)
    like '%can_manage_b2b_dispatch%',
  'ready-to-load uses canonical B2B dispatch role authority'
);
select ok(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure)
    like '%assert_active_dispatch_clearance_v1%',
  'ready-to-load requires active Finance dispatch clearance'
);
select ok(
  not has_function_privilege(
    'service_role',
    'public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)',
    'EXECUTE'
  ),
  'service role cannot mark cartons ready to load'
);

select ok(
  pg_get_functiondef('public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure)
    like '%statement_timestamp() AT TIME ZONE ''Asia/Kolkata''%',
  'final invoice future-date guard uses Asia/Kolkata business date'
);
select ok(
  pg_get_functiondef('public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure)
    not like '%p_invoice_date > current_date%',
  'final invoice no longer compares invoice_date to UTC current_date'
);
select is(
  (timestamptz '2026-09-29 19:00:00+00' AT TIME ZONE 'Asia/Kolkata')::date
    > (timestamptz '2026-09-29 19:00:00+00')::date,
  true,
  'after 18:30 UTC the Kolkata business date can advance before the UTC calendar date'
);

select lives_ok($p100_seed$
DO $p100$
DECLARE
  v_dispatch uuid := '99f10000-0000-0000-0000-000000000001';
  v_sales uuid := '99f10000-0000-0000-0000-000000000002';
  v_finance uuid := '99f10000-0000-0000-0000-000000000003';
  v_company uuid := '99f11000-0000-0000-0000-000000000001';
  v_commercial uuid := '99f12000-0000-0000-0000-000000000001';
  v_pi uuid := '99f13000-0000-0000-0000-000000000001';
  v_dpl_id uuid := '99f14000-0000-0000-0000-000000000001';
  v_invoice uuid := '99f15000-0000-0000-0000-000000000001';
  v_clearance uuid := '99f16000-0000-0000-0000-000000000001';
  v_clearance_revoked uuid := '99f16000-0000-0000-0000-000000000002';
  v_order_happy uuid := '99f20000-0000-0000-0000-000000000001';
  v_order_noclear uuid := '99f20000-0000-0000-0000-000000000002';
  v_order_notcleared uuid := '99f20000-0000-0000-0000-000000000003';
  v_cons_happy uuid := '99f21000-0000-0000-0000-000000000001';
  v_cons_nodpl uuid := '99f21000-0000-0000-0000-000000000002';
  v_cons_noclear uuid := '99f21000-0000-0000-0000-000000000003';
  v_cons_notcleared uuid := '99f21000-0000-0000-0000-000000000004';
  v_line_happy uuid := '99f22000-0000-0000-0000-000000000001';
  v_line_nodpl uuid := '99f22000-0000-0000-0000-000000000002';
  v_line_noclear uuid := '99f22000-0000-0000-0000-000000000003';
  v_line_notcleared uuid := '99f22000-0000-0000-0000-000000000004';
  v_product uuid := '99f23000-0000-0000-0000-000000000001';
  v_item_happy uuid := '99f24000-0000-0000-0000-000000000001';
  v_item_nodpl uuid := '99f24000-0000-0000-0000-000000000002';
  v_item_noclear uuid := '99f24000-0000-0000-0000-000000000003';
  v_item_notcleared uuid := '99f24000-0000-0000-0000-000000000004';
  v_carton_happy uuid := '99f25000-0000-0000-0000-000000000001';
  v_carton_nodpl uuid := '99f25000-0000-0000-0000-000000000002';
  v_carton_noclear uuid := '99f25000-0000-0000-0000-000000000003';
  v_carton_badev uuid := '99f25000-0000-0000-0000-000000000004';
  v_carton_loaded uuid := '99f25000-0000-0000-0000-000000000005';
  v_carton_open uuid := '99f25000-0000-0000-0000-000000000006';
  v_carton_notcleared uuid := '99f25000-0000-0000-0000-000000000007';
  v_dpl_verified uuid := '99f26000-0000-0000-0000-000000000001';
  v_dpl_pending uuid := '99f26000-0000-0000-0000-000000000002';
BEGIN
  set local session_replication_role = replica;

  INSERT INTO auth.users(id, email) VALUES
    (v_dispatch, 'p100-dispatch@test.invalid'),
    (v_sales, 'p100-sales@test.invalid'),
    (v_finance, 'p100-finance@test.invalid')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.users(id, role, name, is_active) VALUES
    (v_dispatch, 'DISPATCH_INCHARGE', 'P100 Dispatch', true),
    (v_sales, 'SALES_EXECUTIVE', 'P100 Sales', true),
    (v_finance, 'FINANCE_EXEC', 'P100 Finance', true)
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  INSERT INTO public.companies(id, business_name, phone, status)
  VALUES (v_company, 'P100 Point100 Co', '+91-9000000100', 'active')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.products(id, name, category, sku, hsn_code, barcode_sku)
  VALUES (v_product, 'P100 Product', 'sweets', 'SKU-P100', '1905', 'BC-P100')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.orders(id, order_number, tracking_token, company_id, sales_order_value, order_origin, status, advance_required, commercial_current_version)
  VALUES
    (v_order_happy, 'PGTAP-P100-HAPPY', 'pgtap-p100-happy', v_company, 100000, 'SALES', 'cleared_for_dispatch', 30000, 1),
    (v_order_noclear, 'PGTAP-P100-NOCLEAR', 'pgtap-p100-noclear', v_company, 100000, 'SALES', 'cleared_for_dispatch', 30000, 1),
    (v_order_notcleared, 'PGTAP-P100-NOTCLEARED', 'pgtap-p100-notcleared', v_company, 100000, 'SALES', 'packed_ready', 30000, 1)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.order_items(id, order_id, product_id, quantity)
  VALUES
    (v_item_happy, v_order_happy, v_product, 10),
    (v_item_nodpl, v_order_happy, v_product, 10),
    (v_item_noclear, v_order_noclear, v_product, 10),
    (v_item_notcleared, v_order_notcleared, v_product, 10)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.b2b_dispatch_consignments(
    id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id
  ) VALUES
    (v_cons_happy, 'PGTAP-P100-HAPPY-DC-01', v_order_happy, 1, 'under_cartonisation', 'road_transporter', 'p100-cons-happy'),
    (v_cons_nodpl, 'PGTAP-P100-HAPPY-DC-02', v_order_happy, 2, 'under_cartonisation', 'road_transporter', 'p100-cons-nodpl'),
    (v_cons_noclear, 'PGTAP-P100-NOCLEAR-DC-01', v_order_noclear, 1, 'under_cartonisation', 'road_transporter', 'p100-cons-noclear'),
    (v_cons_notcleared, 'PGTAP-P100-NOTCLEARED-DC-01', v_order_notcleared, 1, 'under_cartonisation', 'road_transporter', 'p100-cons-notcleared')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.b2b_dispatch_consignment_lines(
    id, consignment_id, order_item_id, product_id, product_code, uom, original_order_qty, selected_qty, accepted_ready_qty, packed_qty
  ) VALUES
    (v_line_happy, v_cons_happy, v_item_happy, v_product, 'SKU-P100', 'PACK', 10, 10, 10, 10),
    (v_line_nodpl, v_cons_nodpl, v_item_nodpl, v_product, 'SKU-P100', 'PACK', 10, 10, 10, 10),
    (v_line_noclear, v_cons_noclear, v_item_noclear, v_product, 'SKU-P100', 'PACK', 10, 10, 10, 10),
    (v_line_notcleared, v_cons_notcleared, v_item_notcleared, v_product, 'SKU-P100', 'PACK', 10, 10, 10, 10)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.b2b_dispatch_cartons(
    id, carton_code, consignment_id, carton_sequence, status, physical_location,
    net_weight, gross_weight, open_photo_ref, locked_by, locked_at, current_version
  ) VALUES
    (v_carton_happy, 'PGTAP-P100-CARTON-HAPPY', v_cons_happy, 1, 'locked', 'TRANSIT_PACKING', 5, 5.5, 'photo-happy', v_dispatch, statement_timestamp(), 1),
    (v_carton_nodpl, 'PGTAP-P100-CARTON-NODPL', v_cons_nodpl, 1, 'locked', 'TRANSIT_PACKING', 5, 5.5, 'photo-nodpl', v_dispatch, statement_timestamp(), 1),
    (v_carton_noclear, 'PGTAP-P100-CARTON-NOCLEAR', v_cons_noclear, 1, 'locked', 'TRANSIT_PACKING', 5, 5.5, 'photo-noclear', v_dispatch, statement_timestamp(), 1),
    (v_carton_badev, 'PGTAP-P100-CARTON-BADEV', v_cons_happy, 2, 'locked', 'TRANSIT_PACKING', 5, 5.5, 'photo-badev', v_dispatch, statement_timestamp(), 1),
    (v_carton_loaded, 'PGTAP-P100-CARTON-LOADED', v_cons_happy, 3, 'loaded', 'LOADED', 5, 5.5, 'photo-loaded', v_dispatch, statement_timestamp(), 1),
    (v_carton_open, 'PGTAP-P100-CARTON-OPEN', v_cons_happy, 4, 'open', 'CONSOLIDATION_ZONE', NULL, NULL, NULL, NULL, NULL, 1),
    (v_carton_notcleared, 'PGTAP-P100-CARTON-NOTCLEARED', v_cons_notcleared, 1, 'locked', 'TRANSIT_PACKING', 5, 5.5, 'photo-notcleared', v_dispatch, statement_timestamp(), 1)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.b2b_dispatch_carton_items(
    id, carton_id, consignment_line_id, order_item_id, product_id, product_code, barcode_value, batch_lot, uom, quantity, scanned_by
  ) VALUES
    (gen_random_uuid(), v_carton_happy, v_line_happy, v_item_happy, v_product, 'SKU-P100', 'BC-P100', 'BATCH-1', 'PACK', 10, v_dispatch),
    (gen_random_uuid(), v_carton_nodpl, v_line_nodpl, v_item_nodpl, v_product, 'SKU-P100', 'BC-P100', 'BATCH-2', 'PACK', 10, v_dispatch),
    (gen_random_uuid(), v_carton_noclear, v_line_noclear, v_item_noclear, v_product, 'SKU-P100', 'BC-P100', 'BATCH-3', 'PACK', 10, v_dispatch),
    (gen_random_uuid(), v_carton_loaded, v_line_happy, v_item_happy, v_product, 'SKU-P100', 'BC-P100', 'BATCH-5', 'PACK', 10, v_dispatch),
    (gen_random_uuid(), v_carton_notcleared, v_line_notcleared, v_item_notcleared, v_product, 'SKU-P100', 'BC-P100', 'BATCH-6', 'PACK', 10, v_dispatch)
  ON CONFLICT DO NOTHING;

  INSERT INTO public.b2b_dispatch_packing_list_versions(
    id, consignment_id, version_number, status, physical_truth_snapshot, finance_check_state, correlation_id, submitted_to_finance_at
  ) VALUES
    (v_dpl_verified, v_cons_happy, 1, 'finance_verified', '{}'::jsonb, 'verified', 'p100-dpl-verified', statement_timestamp()),
    (v_dpl_pending, v_cons_nodpl, 1, 'submitted_to_finance', '{}'::jsonb, 'pending', 'p100-dpl-pending', statement_timestamp()),
    (gen_random_uuid(), v_cons_noclear, 1, 'finance_verified', '{}'::jsonb, 'verified', 'p100-dpl-noclear', statement_timestamp()),
    (gen_random_uuid(), v_cons_notcleared, 1, 'finance_verified', '{}'::jsonb, 'verified', 'p100-dpl-notcleared', statement_timestamp())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.sales_order_commercial_versions(
    id, order_id, version_number, source_channel, commercial_snapshot, snapshot_fingerprint,
    sales_order_value, advance_required, change_reason, correlation_id, idempotency_key, created_by
  ) VALUES (
    v_commercial, v_order_happy, 1, 'MANUAL', '{}'::jsonb, 'p100-commercial-fp', 100000, 30000,
    'pgtap fixture', 'p100-commercial', 'p100-commercial-key', v_finance
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.sales_order_proforma_invoices(
    id, order_id, commercial_version_id, commercial_version_number, frozen_commercial_snapshot,
    frozen_snapshot_fingerprint, status, customer_visible_pi_number, reason, source, correlation_id, idempotency_key, created_by, issued_by, issued_at
  ) VALUES (
    v_pi, v_order_happy, v_commercial, 1, '{}'::jsonb, 'p100-commercial-fp', 'ISSUED', 'PI2026/09-001', 'pgtap fixture', 'MANUAL',
    'p100-pi', 'p100-pi-key', v_finance, v_finance, statement_timestamp()
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.finance_dpl_receipts(
    id, order_id, company_id, commercial_version_id, external_dpl_id, dpl_version, dpl_fingerprint,
    dpl_snapshot, finalized_at, received_by, received_role, source_channel, evidence_reference, correlation_id, idempotency_key
  ) VALUES (
    v_dpl_id, v_order_happy, v_company, v_commercial, 'P100-DPL-1', 1, repeat('a', 64),
    jsonb_build_object('lines', '[]'::jsonb), statement_timestamp(), v_finance, 'FINANCE_EXEC', 'FINANCE', 'p100-dpl-evidence', 'p100-dpl', 'p100-dpl-key'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.final_invoices(
    id, order_id, company_id, proforma_invoice_id, commercial_version_id, finance_dpl_receipt_id,
    invoice_number, invoice_date, taxable_total, tax_total, gross_total, status, document_reference,
    invoice_fingerprint, issued_by, issued_role, reason, correlation_id, idempotency_key
  ) VALUES (
    v_invoice, v_order_happy, v_company, v_pi, v_commercial, v_dpl_id, 'P100-INV-1', current_date,
    84745.76, 15254.24, 100000, 'ISSUED', 'p100-invoice-doc', repeat('b', 64), v_finance, 'FINANCE_EXEC',
    'pgtap fixture', 'p100-invoice', 'p100-invoice-key'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.finance_clearance_events(
    id, order_id, company_id, proforma_invoice_id, commercial_version_id, clearance_type, decision,
    commercial_value, required_advance, verified_payment_amount, wallet_applied_amount, approved_credit_amount,
    covered_amount, reason, evidence_reference, actor_id, actor_role, source_channel, source_reference,
    correlation_id, idempotency_key, facts_snapshot, created_at
  ) VALUES
    (
      v_clearance, v_order_happy, v_company, v_pi, v_commercial, 'DISPATCH', 'GRANTED',
      100000, 0, 100000, 0, 0, 100000, 'p100 active clearance', 'p100-clearance-evidence', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'p100-clearance-grant', 'p100-clearance-grant-key',
      '{}'::jsonb, statement_timestamp() - interval '1 hour'
    ),
    (
      v_clearance_revoked, v_order_noclear, v_company, v_pi, v_commercial, 'DISPATCH', 'GRANTED',
      100000, 0, 100000, 0, 0, 100000, 'p100 revoked clearance grant', 'p100-revoked-grant', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'p100-revoked-grant', 'p100-revoked-grant-key',
      '{}'::jsonb, statement_timestamp() - interval '2 hours'
    ),
    (
      gen_random_uuid(), v_order_noclear, v_company, v_pi, v_commercial, 'DISPATCH', 'REVOKED',
      100000, 0, 100000, 0, 0, 100000, 'p100 revoked clearance revoke', 'p100-revoked-revoke', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'p100-revoked-revoke', 'p100-revoked-revoke-key',
      '{}'::jsonb, statement_timestamp() - interval '30 minutes'
    )
  ON CONFLICT (id) DO NOTHING;

  set local session_replication_role = default;
END;
$p100$ $p100_seed$, 'Point100 fixtures seed cleanly');

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99f10000-0000-0000-0000-000000000002', 'role', 'authenticated', 'aal', 'aal2')::text,
  true
);

select throws_ok(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000001'::uuid, 1, 'p100-unauth')$$,
  'Not authorised to mark a dispatch carton ready to load',
  'non-dispatch role cannot mark a carton ready to load'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99f10000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal2')::text,
  true
);

select throws_ok(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000002'::uuid, 1, 'p100-nodpl')$$,
  'CARTON_READY_TO_LOAD_FINANCE_DPL_NOT_VERIFIED',
  'missing Finance DPL verification is rejected'
);

select throws_ok(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000003'::uuid, 1, 'p100-noclear')$$,
  'FINANCE_DISPATCH_CLEARANCE_REQUIRED',
  'missing active dispatch clearance is rejected'
);

select throws_ok(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000007'::uuid, 1, 'p100-notcleared')$$,
  'ORDER_NOT_CLEARED_FOR_DISPATCH',
  'order not cleared_for_dispatch is rejected'
);

select throws_like(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000004'::uuid, 1, 'p100-noitems')$$,
  '%has no scanned contents%',
  'carton without scanned contents is rejected'
);

select throws_like(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000001'::uuid, 99, 'p100-stale')$$,
  '%has changed since it was loaded%',
  'stale expected_version is rejected'
);

select throws_like(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000006'::uuid, 1, 'p100-open')$$,
  '%cannot be marked ready to load from this state%',
  'invalid carton state is rejected'
);

select throws_like(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000005'::uuid, 1, 'p100-loaded')$$,
  '%loaded and cannot be marked ready to load%',
  'loaded cartons do not regress to ready_to_load'
);

select lives_ok(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000001'::uuid, 1, 'p100-happy')$$,
  'happy path marks carton ready to load'
);
select is(
  (select status from public.b2b_dispatch_cartons where id = '99f25000-0000-0000-0000-000000000001'::uuid),
  'ready_to_load',
  'happy path sets ready_to_load status'
);
select is(
  (select physical_location from public.b2b_dispatch_cartons where id = '99f25000-0000-0000-0000-000000000001'::uuid),
  'READY_TO_LOAD_BAY',
  'happy path sets READY_TO_LOAD_BAY location'
);
select is(
  (select count(*) from public.b2b_dispatch_events where carton_id = '99f25000-0000-0000-0000-000000000001'::uuid and event_type = 'carton_ready_to_load'),
  1::bigint,
  'happy path records one carton_ready_to_load audit event'
);

select lives_ok(
  $$select public.mark_b2b_dispatch_carton_ready_to_load_v1('99f25000-0000-0000-0000-000000000001'::uuid, 2, 'p100-replay')$$,
  'replay on already ready_to_load carton is idempotent'
);
select is(
  (select count(*) from public.b2b_dispatch_events where carton_id = '99f25000-0000-0000-0000-000000000001'::uuid and event_type = 'carton_ready_to_load'),
  1::bigint,
  'idempotent replay does not duplicate audit events'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99f10000-0000-0000-0000-000000000003', 'role', 'authenticated', 'aal', 'aal2')::text,
  true
);

select throws_ok(
  format(
    $select * from public.issue_final_invoice_v1(
      '99f20000-0000-0000-0000-000000000001'::uuid,
      '99f13000-0000-0000-0000-000000000001'::uuid,
      '99f12000-0000-0000-0000-000000000001'::uuid,
      '99f14000-0000-0000-0000-000000000001'::uuid,
      'P100-INV-TODAY', %L::date, 'doc-ref', 'reason ok',
      'p100-inv-today-corr', 'p100-inv-today-idem'
    )$,
    ((statement_timestamp() AT TIME ZONE 'Asia/Kolkata')::date)::text
  ),
  'FINAL_INVOICE_DPL_LINES_REQUIRED',
  'today in Kolkata passes the future-date guard and reaches later DPL validation'
);

select ok(
  pg_get_functiondef(
    'public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure
  ) like '%HAVING count(*) > 1%',
  'final invoice authority rejects duplicate Finance DPL order-item/product rows'
);

select throws_ok(
  format(
    $$select * from public.issue_final_invoice_v1(
      '99f20000-0000-0000-0000-000000000001'::uuid,
      '99f13000-0000-0000-0000-000000000001'::uuid,
      '99f12000-0000-0000-0000-000000000001'::uuid,
      '99f14000-0000-0000-0000-000000000001'::uuid,
      'P100-INV-FUTURE', %L::date, 'doc-ref', 'reason ok', 'p100-inv-future-corr', 'p100-inv-future-idem'
    )$$,
    ((statement_timestamp() AT TIME ZONE 'Asia/Kolkata')::date + 1)::text
  ),
  'FINAL_INVOICE_EVIDENCE_REQUIRED',
  'invoice dates beyond the India business date remain rejected'
);

select * from finish();
rollback;
