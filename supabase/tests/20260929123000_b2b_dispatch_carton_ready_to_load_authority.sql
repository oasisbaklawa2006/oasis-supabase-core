-- Contract test for migration 20260929123000_b2b_dispatch_carton_ready_to_load_authority.sql.
BEGIN;
SELECT plan(20);

SELECT pass('20260929123000_b2b_dispatch_carton_ready_to_load_authority.sql contract');

SELECT has_function(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'ready-to-load transition RPC exists'
);

SELECT function_lang_is(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'plpgsql',
  'ready-to-load RPC uses plpgsql'
);

SELECT function_privs_are(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'anon',
  ARRAY[]::text[],
  'anon cannot execute ready-to-load transition'
);

SELECT function_privs_are(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'service_role',
  ARRAY[]::text[],
  'service_role cannot bypass authenticated actor boundary'
);

SELECT function_privs_are(
  'public',
  'mark_b2b_dispatch_carton_ready_to_load_v1',
  ARRAY['uuid','integer','text'],
  'authenticated',
  ARRAY['EXECUTE'],
  'authenticated may invoke governed transition'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%can_manage_b2b_dispatch%',
  'RPC enforces Dispatch authority'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%assert_active_dispatch_clearance_v1%',
  'RPC requires active Finance Dispatch Clearance'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%final_invoices%',
  'RPC requires issued final invoice'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%finance_dpl_receipts%',
  'RPC requires governed final DPL'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%eway_bill_evidence%',
  'RPC requires E-way evidence'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%current_version = p_expected_version%',
  'RPC enforces optimistic concurrency'
);

SELECT like(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%carton_ready_to_load%',
  'RPC records an audit event'
);

SELECT unlike(
  pg_get_functiondef('public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid,integer,text)'::regprocedure),
  '%GRANT%service_role%',
  'RPC body contains no service-role bypass'
);

SELECT lives_ok($fixture$
DO $seed$
DECLARE
  v_dispatch uuid := 'b3660000-0000-4000-8000-000000000001';
  v_finance uuid := 'b3660000-0000-4000-8000-000000000002';
  v_company uuid := 'b3660000-0000-4000-8000-000000000010';
  v_order uuid := 'b3660000-0000-4000-8000-000000000020';
  v_consignment uuid := 'b3660000-0000-4000-8000-000000000030';
  v_carton uuid := 'b3660000-0000-4000-8000-000000000040';
  v_commercial uuid := 'b3660000-0000-4000-8000-000000000050';
  v_pi uuid := 'b3660000-0000-4000-8000-000000000060';
  v_dpl uuid := 'b3660000-0000-4000-8000-000000000070';
  v_invoice uuid := 'b3660000-0000-4000-8000-000000000080';
  v_clearance uuid := 'b3660000-0000-4000-8000-000000000090';
BEGIN
  SET LOCAL session_replication_role = replica;

  INSERT INTO auth.users(id,email) VALUES
    (v_dispatch,'b366-dispatch@test.invalid'),
    (v_finance,'b366-finance@test.invalid');

  INSERT INTO public.users(id,role,name,is_active) VALUES
    (v_dispatch,'DISPATCH_MANAGER','B366 Dispatch',true),
    (v_finance,'FINANCE_EXEC','B366 Finance',true);

  INSERT INTO public.companies(id,business_name,status)
  VALUES (v_company,'B366 Ready-to-load Co','active');

  INSERT INTO public.orders(
    id,company_id,order_number,order_origin,tracking_token,status,sales_order_value,advance_required
  ) VALUES (
    v_order,v_company,'B366-ORDER','MANUAL','b366-order','cleared_for_dispatch',118,0
  );

  INSERT INTO public.b2b_dispatch_consignments(
    id,consignment_number,order_id,sequence_number,status,dispatch_mode,correlation_id
  ) VALUES (
    v_consignment,'B366-CONS-1',v_order,1,'finance_check','road_transporter','b366-consignment'
  );

  INSERT INTO public.b2b_dispatch_cartons(
    id,carton_code,consignment_id,carton_sequence,status,physical_location,
    net_weight,gross_weight,open_photo_ref,locked_by,locked_at,current_version
  ) VALUES (
    v_carton,'B366-CTN-1',v_consignment,1,'locked','CONSOLIDATION_ZONE',
    1.0,1.2,'b366://carton-photo',v_dispatch,statement_timestamp() - interval '10 minutes',7
  );

  INSERT INTO public.finance_dpl_receipts(
    id,order_id,company_id,commercial_version_id,external_dpl_id,dpl_version,dpl_fingerprint,
    dpl_snapshot,finalized_at,received_by,received_role,source_channel,evidence_reference,
    correlation_id,idempotency_key
  ) VALUES (
    v_dpl,v_order,v_company,v_commercial,'B366-DPL-1',1,
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    jsonb_build_object(
      'source_authority','b2b_dispatch_packing_list_versions',
      'carton_ids',jsonb_build_array(v_carton::text)
    ),
    statement_timestamp() - interval '5 minutes',
    v_finance,'FINANCE_EXEC','FINANCE','b366://dpl','b366-dpl','b366-dpl-key'
  );

  INSERT INTO public.final_invoices(
    id,order_id,company_id,proforma_invoice_id,commercial_version_id,finance_dpl_receipt_id,
    invoice_number,invoice_date,taxable_total,tax_total,gross_total,status,document_reference,
    invoice_fingerprint,issued_by,issued_role,reason,correlation_id,idempotency_key
  ) VALUES (
    v_invoice,v_order,v_company,v_pi,v_commercial,v_dpl,
    'B366-INV-1',current_date,100,18,118,'ISSUED','b366://invoice',
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    v_finance,'FINANCE_EXEC','behavioral fixture','b366-invoice','b366-invoice-key'
  );

  INSERT INTO public.finance_clearance_events(
    id,order_id,company_id,proforma_invoice_id,commercial_version_id,clearance_type,decision,
    commercial_value,required_advance,verified_payment_amount,wallet_applied_amount,
    approved_credit_amount,covered_amount,reason,evidence_reference,actor_id,actor_role,
    source_channel,source_reference,correlation_id,idempotency_key,facts_snapshot,created_at
  ) VALUES (
    v_clearance,v_order,v_company,v_pi,v_commercial,'DISPATCH','GRANTED',
    118,0,118,0,0,118,'behavioral fixture','b366://clearance',v_finance,'FINANCE_EXEC',
    'FINANCE',v_invoice::text,'b366-clearance','b366-clearance-key','{}'::jsonb,
    statement_timestamp() - interval '4 minutes'
  );

  INSERT INTO public.eway_bill_evidence(
    id,order_id,final_invoice_id,status,policy_reason,actor_id,actor_role,correlation_id,idempotency_key
  ) VALUES (
    'b3660000-0000-4000-8000-0000000000a0',
    v_order,v_invoice,'NOT_REQUIRED','behavioral fixture below policy threshold',
    v_finance,'FINANCE_EXEC','b366-eway','b366-eway-key'
  );

  SET LOCAL session_replication_role = default;
END
$seed$;
$fixture$, 'ready-to-load behavioral prerequisites seed cleanly');

SELECT lives_ok($call$
  SELECT set_config(
    'request.jwt.claims',
    json_build_object(
      'sub','b3660000-0000-4000-8000-000000000001',
      'role','authenticated'
    )::text,
    true
  );
  SET LOCAL ROLE authenticated;
  SELECT public.mark_b2b_dispatch_carton_ready_to_load_v1(
    'b3660000-0000-4000-8000-000000000040'::uuid,
    7,
    'b366-ready-transition'
  );
  RESET ROLE;
$call$, 'authenticated Dispatch actor can execute governed ready-to-load transition');

SELECT is(
  (SELECT status FROM public.b2b_dispatch_cartons WHERE id='b3660000-0000-4000-8000-000000000040'::uuid),
  'ready_to_load',
  'transition persists ready_to_load carton status'
);

SELECT is(
  (SELECT current_version FROM public.b2b_dispatch_cartons WHERE id='b3660000-0000-4000-8000-000000000040'::uuid),
  8,
  'transition increments carton current_version'
);

SELECT is(
  (SELECT physical_location FROM public.b2b_dispatch_cartons WHERE id='b3660000-0000-4000-8000-000000000040'::uuid),
  'READY_TO_LOAD_BAY',
  'transition persists ready-to-load physical location'
);

SELECT is(
  (
    SELECT count(*)::integer
    FROM public.b2b_dispatch_events
    WHERE carton_id='b3660000-0000-4000-8000-000000000040'::uuid
      AND event_type='carton_ready_to_load'
      AND old_status='locked'
      AND new_status='ready_to_load'
      AND correlation_id='b366-ready-transition'
  ),
  1,
  'transition records one governed carton_ready_to_load audit event'
);

SELECT * FROM finish();
ROLLBACK;
