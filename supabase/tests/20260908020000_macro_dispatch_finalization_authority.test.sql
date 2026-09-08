-- Contract and behavioral coverage for 20260908020000_macro_dispatch_finalization_authority.sql
begin;
select plan(31);

select has_function(
  'public',
  'release_order_to_dispatched_v1',
  array['uuid','text','text','text','text'],
  'canonical order dispatch finalizer exists'
);

select ok(
  (select prosecdef from pg_proc where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure),
  'dispatch finalizer is SECURITY DEFINER'
);

select ok(
  has_function_privilege('authenticated', 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)', 'EXECUTE'),
  'authenticated internal operators can call governed dispatch finalization'
);

select ok(
  not has_function_privilege('anon', 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)', 'EXECUTE')
  and not has_function_privilege('public', 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)', 'EXECUTE'),
  'anonymous, PUBLIC and detached service-role execution are denied'
);

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%auth.uid()%'
    and pg_get_functiondef(oid) like '%is_internal_staff%'
    and pg_get_functiondef(oid) like '%DISPATCH_FINALIZATION_ACTOR_REQUIRED%'
$$, 'dispatch finalization binds the authenticated internal actor');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%assert_order_transition_role(''gate_release'')%'
$$, 'dispatch finalization reuses the canonical physical-exit role boundary');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%FROM public.dispatch_proof_packets%'
    and pg_get_functiondef(oid) like '%dispatch_proof_required%'
$$, 'immutable post-gate dispatch proof is mandatory');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%assert_active_dispatch_clearance_v1%'
    and pg_get_functiondef(oid) like '%finance_dispatch_clearance_required%'
$$, 'active Finance dispatch clearance is revalidated at finalization time');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%tracking_reference%'
    and pg_get_functiondef(oid) like '%lr_awb_bilty%'
    and pg_get_functiondef(oid) like '%transporter%'
    and pg_get_functiondef(oid) like '%tracking_reference_mismatch%'
    and pg_get_functiondef(oid) like '%courier_mismatch%'
$$, 'optional caller transport fields validate against frozen proof rather than replacing it');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%cleared_for_dispatch%'
    and pg_get_functiondef(oid) like '%invalid_status%'
    and pg_get_functiondef(oid) like '%already_applied%'
$$, 'only cleared_for_dispatch advances and dispatched replay is idempotent');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%UPDATE public.orders%'
    and pg_get_functiondef(oid) like '%SET status = ''dispatched''%'
    and pg_get_functiondef(oid) like '%INSERT INTO public.order_status_history%'
$$, 'finalizer atomically writes the canonical order state and status history');

select isnt_empty($$
  select 1 from pg_proc
  where oid='public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    and pg_get_functiondef(oid) like '%INSERT INTO public.audit_logs%'
    and pg_get_functiondef(oid) like '%ORDER_DISPATCHED%'
    and pg_get_functiondef(oid) like '%dispatch_proof_fingerprint%'
    and pg_get_functiondef(oid) like '%finance_dispatch_clearance_event_id%'
$$, 'high-risk dispatch audit is bound to canonical proof and Finance clearance');

select ok(
  coalesce(
    (
      select 'lock_timeout=5s' = any(proconfig)
      from pg_proc
      where oid = 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    ),
    false
  ),
  'dispatch finalizer applies runtime lock_timeout on every invocation'
);

select ok(
  coalesce(
    (
      select 'statement_timeout=60s' = any(proconfig)
      from pg_proc
      where oid = 'public.release_order_to_dispatched_v1(uuid,text,text,text,text)'::regprocedure
    ),
    false
  ),
  'dispatch finalizer applies runtime statement_timeout on every invocation'
);

select lives_ok($md0802_seed$
DO $md0802$
DECLARE
  v_dispatch uuid := 'd8020000-0000-0000-0000-000000000001';
  v_finance uuid := 'd8020000-0000-0000-0000-000000000002';
  v_company uuid := 'd8020000-0000-0000-0000-000000000010';
  v_commercial uuid := 'd8020000-0000-0000-0000-000000000011';
  v_pi uuid := 'd8020000-0000-0000-0000-000000000012';
  v_dpl uuid := 'd8020000-0000-0000-0000-000000000013';
  v_invoice uuid := 'd8020000-0000-0000-0000-000000000014';
  v_clearance uuid := 'd8020000-0000-0000-0000-000000000015';
  v_transport jsonb := jsonb_build_object(
    'transporter', 'BlueDart',
    'lr_awb_bilty', 'AWB-MD0802',
    'tracking_reference', 'TRK-MD0802'
  );
  v_fingerprint text := 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
BEGIN
  set local session_replication_role = replica;

  INSERT INTO auth.users(id, email) VALUES
    (v_dispatch, 'md0802-dispatch@test.invalid'),
    (v_finance, 'md0802-finance@test.invalid')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.users(id, role, name, is_active) VALUES
    (v_dispatch, 'DISPATCH_MANAGER', 'MD0802 Dispatch', true),
    (v_finance, 'FINANCE_EXEC', 'MD0802 Finance', true)
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  INSERT INTO public.companies(id, business_name, status)
  VALUES (v_company, 'MD0802 Dispatch Finalize Co', 'active')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.orders(id, company_id, order_number, order_origin, tracking_token, sales_order_value, advance_required, status)
  VALUES
    ('d8020000-0000-0000-0000-000000000020', v_company, 'MD0802-NO-PROOF', 'MANUAL', 'md0802-no-proof', 100000, 30000, 'cleared_for_dispatch'),
    ('d8020000-0000-0000-0000-000000000021', v_company, 'MD0802-REVOKED', 'MANUAL', 'md0802-revoked', 100000, 30000, 'cleared_for_dispatch'),
    ('d8020000-0000-0000-0000-000000000022', v_company, 'MD0802-SUCCESS', 'MANUAL', 'md0802-success', 100000, 30000, 'cleared_for_dispatch'),
    ('d8020000-0000-0000-0000-000000000023', v_company, 'MD0802-REPLAY', 'MANUAL', 'md0802-replay', 100000, 30000, 'dispatched'),
    ('d8020000-0000-0000-0000-000000000024', v_company, 'MD0802-BAD-STATUS', 'MANUAL', 'md0802-bad-status', 100000, 30000, 'packed_ready'),
    ('d8020000-0000-0000-0000-000000000025', v_company, 'MD0802-TRANSPORT', 'MANUAL', 'md0802-transport', 100000, 30000, 'cleared_for_dispatch')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.sales_order_commercial_versions(
    id, order_id, version_number, source_channel, commercial_snapshot, snapshot_fingerprint,
    sales_order_value, advance_required, change_reason, correlation_id, idempotency_key, created_by
  ) VALUES (
    v_commercial, 'd8020000-0000-0000-0000-000000000022', 1, 'MANUAL', '{}'::jsonb,
    'md0802-commercial-fingerprint', 100000, 30000, 'pgtap fixture', 'md0802-commercial', 'md0802-commercial-key', v_finance
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.sales_order_proforma_invoices(
    id, order_id, commercial_version_id, commercial_version_number, frozen_commercial_snapshot,
    frozen_snapshot_fingerprint, status, customer_visible_pi_number, reason, source, correlation_id, idempotency_key, created_by,
    issued_by, issued_at
  ) VALUES (
    v_pi, 'd8020000-0000-0000-0000-000000000022', v_commercial, 1, '{}'::jsonb,
    'md0802-pi-fingerprint', 'ISSUED', 'PI2026/09-001', 'pgtap fixture', 'MANUAL', 'md0802-pi', 'md0802-pi-key', v_finance,
    v_finance, statement_timestamp()
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.finance_dpl_receipts(
    id, order_id, company_id, commercial_version_id, external_dpl_id, dpl_version, dpl_fingerprint,
    dpl_snapshot, finalized_at, received_by, received_role, source_channel, evidence_reference,
    correlation_id, idempotency_key
  ) VALUES (
    v_dpl, 'd8020000-0000-0000-0000-000000000022', v_company, v_commercial, 'MD0802-DPL-1', 1,
    v_fingerprint, jsonb_build_object('carton_ids', '[]'::jsonb), statement_timestamp(),
    v_finance, 'FINANCE_EXEC', 'FINANCE', 'md0802-dpl-evidence', 'md0802-dpl', 'md0802-dpl-key'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.final_invoices(
    id, order_id, company_id, proforma_invoice_id, commercial_version_id, finance_dpl_receipt_id,
    invoice_number, invoice_date, taxable_total, tax_total, gross_total, status, document_reference,
    invoice_fingerprint, issued_by, issued_role, reason, correlation_id, idempotency_key
  ) VALUES (
    v_invoice, 'd8020000-0000-0000-0000-000000000022', v_company, v_pi, v_commercial, v_dpl,
    'MD0802-INV-1', current_date, 84745.76, 15254.24, 100000, 'ISSUED', 'md0802-invoice-doc',
    v_fingerprint, v_finance, 'FINANCE_EXEC', 'pgtap fixture', 'md0802-invoice', 'md0802-invoice-key'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.finance_clearance_events(
    id, order_id, company_id, proforma_invoice_id, commercial_version_id, clearance_type, decision,
    commercial_value, required_advance, verified_payment_amount, wallet_applied_amount,
    approved_credit_amount, covered_amount, reason, evidence_reference, actor_id, actor_role,
    source_channel, source_reference, correlation_id, idempotency_key, facts_snapshot, created_at
  ) VALUES
    (
      v_clearance, 'd8020000-0000-0000-0000-000000000022', v_company, v_pi, v_commercial, 'DISPATCH', 'GRANTED',
      100000, 0, 100000, 0, 0, 100000, 'pgtap active clearance', 'md0802-clearance-evidence', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'md0802-clearance-grant', 'md0802-clearance-grant-key',
      '{}'::jsonb, statement_timestamp() - interval '2 hours'
    ),
    (
      'd8020000-0000-0000-0000-000000000016', 'd8020000-0000-0000-0000-000000000021', v_company, v_pi, v_commercial, 'DISPATCH', 'GRANTED',
      100000, 0, 100000, 0, 0, 100000, 'pgtap revoked clearance grant', 'md0802-revoked-grant', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'md0802-revoked-grant', 'md0802-revoked-grant-key',
      '{}'::jsonb, statement_timestamp() - interval '2 hours'
    ),
    (
      'd8020000-0000-0000-0000-000000000017', 'd8020000-0000-0000-0000-000000000021', v_company, v_pi, v_commercial, 'DISPATCH', 'REVOKED',
      100000, 0, 100000, 0, 0, 100000, 'pgtap revoked clearance revoke', 'md0802-revoked-revoke', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'md0802-revoked-revoke', 'md0802-revoked-revoke-key',
      '{}'::jsonb, statement_timestamp() - interval '1 hour'
    ),
    (
      'd8020000-0000-0000-0000-000000000018', 'd8020000-0000-0000-0000-000000000023', v_company, v_pi, v_commercial, 'DISPATCH', 'GRANTED',
      100000, 0, 100000, 0, 0, 100000, 'pgtap replay original grant', 'md0802-replay-grant', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'md0802-replay-grant', 'md0802-replay-grant-key',
      '{}'::jsonb, statement_timestamp() - interval '3 hours'
    ),
    (
      'd8020000-0000-0000-0000-000000000019', 'd8020000-0000-0000-0000-000000000023', v_company, v_pi, v_commercial, 'DISPATCH', 'REVOKED',
      100000, 0, 100000, 0, 0, 100000, 'pgtap replay post-dispatch revoke', 'md0802-replay-revoke', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'md0802-replay-revoke', 'md0802-replay-revoke-key',
      '{}'::jsonb, statement_timestamp() - interval '30 minutes'
    ),
    (
      'd8020000-0000-0000-0000-00000000001a', 'd8020000-0000-0000-0000-000000000024', v_company, v_pi, v_commercial, 'DISPATCH', 'GRANTED',
      100000, 0, 100000, 0, 0, 100000, 'pgtap bad status clearance', 'md0802-bad-status-clearance', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'md0802-bad-status-clearance', 'md0802-bad-status-clearance-key',
      '{}'::jsonb, statement_timestamp() - interval '2 hours'
    ),
    (
      'd8020000-0000-0000-0000-00000000001b', 'd8020000-0000-0000-0000-000000000025', v_company, v_pi, v_commercial, 'DISPATCH', 'GRANTED',
      100000, 0, 100000, 0, 0, 100000, 'pgtap transport mismatch clearance', 'md0802-transport-clearance', v_finance,
      'FINANCE_EXEC', 'FINANCE', v_invoice::text, 'md0802-transport-clearance', 'md0802-transport-clearance-key',
      '{}'::jsonb, statement_timestamp() - interval '2 hours'
    )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.dispatch_proof_packets(
    id, order_id, final_invoice_id, finance_dpl_receipt_id, finance_dispatch_clearance_event_id,
    transport_snapshot, gate_decision_ids, evidence_references, dispatched_at, proof_fingerprint,
    recorded_by, recorded_role, correlation_id, idempotency_key
  ) VALUES
    (
      'd8020000-0000-0000-0000-000000000031', 'd8020000-0000-0000-0000-000000000021', v_invoice, v_dpl,
      'd8020000-0000-0000-0000-000000000016', v_transport, '[]'::jsonb, '["md0802-evidence"]'::jsonb,
      statement_timestamp() - interval '90 minutes', v_fingerprint, v_dispatch, 'DISPATCH_MANAGER',
      'md0802-proof-revoked', 'md0802-proof-revoked-key'
    ),
    (
      'd8020000-0000-0000-0000-000000000032', 'd8020000-0000-0000-0000-000000000022', v_invoice, v_dpl,
      v_clearance, v_transport, '[]'::jsonb, '["md0802-evidence"]'::jsonb,
      statement_timestamp() - interval '90 minutes', v_fingerprint, v_dispatch, 'DISPATCH_MANAGER',
      'md0802-proof-success', 'md0802-proof-success-key'
    ),
    (
      'd8020000-0000-0000-0000-000000000033', 'd8020000-0000-0000-0000-000000000023', v_invoice, v_dpl,
      'd8020000-0000-0000-0000-000000000018', v_transport, '[]'::jsonb, '["md0802-evidence"]'::jsonb,
      statement_timestamp() - interval '2 hours', v_fingerprint, v_dispatch, 'DISPATCH_MANAGER',
      'md0802-proof-replay', 'md0802-proof-replay-key'
    ),
    (
      'd8020000-0000-0000-0000-000000000034', 'd8020000-0000-0000-0000-000000000024', v_invoice, v_dpl,
      'd8020000-0000-0000-0000-00000000001a', v_transport, '[]'::jsonb, '["md0802-evidence"]'::jsonb,
      statement_timestamp() - interval '90 minutes', v_fingerprint, v_dispatch, 'DISPATCH_MANAGER',
      'md0802-proof-bad-status', 'md0802-proof-bad-status-key'
    ),
    (
      'd8020000-0000-0000-0000-000000000035', 'd8020000-0000-0000-0000-000000000025', v_invoice, v_dpl,
      'd8020000-0000-0000-0000-00000000001b', v_transport, '[]'::jsonb, '["md0802-evidence"]'::jsonb,
      statement_timestamp() - interval '90 minutes', v_fingerprint, v_dispatch, 'DISPATCH_MANAGER',
      'md0802-proof-transport', 'md0802-proof-transport-key'
    )
  ON CONFLICT (id) DO NOTHING;

  set local session_replication_role = default;
END;
$md0802$;
$md0802_seed$, 'dispatch finalization behavioral fixtures seed cleanly');

select lives_ok($$
  select set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', 'd8020000-0000-0000-0000-000000000001',
      'role', 'authenticated'
    )::text,
    true
  )
$$, 'dispatch finalization behavioral actor JWT is configured');

set local role authenticated;

select is(
  (public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000020'::uuid)->>'ok')::boolean,
  false,
  'missing dispatch proof returns ok=false'
);

select is(
  public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000020'::uuid)->'blockers'->0->>'code',
  'dispatch_proof_required',
  'missing dispatch proof reports dispatch_proof_required blocker'
);

select is(
  (public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000021'::uuid)->>'ok')::boolean,
  false,
  'revoked Finance dispatch clearance rejects a new finalization'
);

select is(
  public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000021'::uuid)->'blockers'->0->>'code',
  'finance_dispatch_clearance_required',
  'revoked Finance dispatch clearance reports finance_dispatch_clearance_required'
);

select is(
  (public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000024'::uuid)->>'ok')::boolean,
  false,
  'invalid predecessor status rejects finalization'
);

select is(
  public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000024'::uuid)->'blockers'->0->>'code',
  'invalid_status',
  'invalid predecessor status reports invalid_status blocker'
);

select is(
  (public.release_order_to_dispatched_v1(
    'd8020000-0000-0000-0000-000000000025'::uuid,
    'WRONG-TRACK',
    'BlueDart'
  )->>'ok')::boolean,
  false,
  'transport mismatch rejects finalization'
);

select is(
  public.release_order_to_dispatched_v1(
    'd8020000-0000-0000-0000-000000000025'::uuid,
    'WRONG-TRACK',
    'BlueDart'
  )->'blockers'->0->>'code',
  'tracking_reference_mismatch',
  'transport mismatch reports tracking_reference_mismatch blocker'
);

select is(
  (public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000022'::uuid)->>'ok')::boolean,
  true,
  'cleared_for_dispatch order with proof and active clearance dispatches successfully'
);

select is(
  (select status from public.orders where id = 'd8020000-0000-0000-0000-000000000022'),
  'dispatched',
  'successful finalization persists dispatched order status'
);

reset role;

select is(
  (
    select count(*)::integer
    from public.order_status_history
    where order_id = 'd8020000-0000-0000-0000-000000000022'
      and old_status = 'cleared_for_dispatch'
      and new_status = 'dispatched'
  ),
  1,
  'successful finalization appends order_status_history'
);

select is(
  (
    select count(*)::integer
    from public.audit_logs
    where entity_id = 'd8020000-0000-0000-0000-000000000022'
      and action_type = 'ORDER_DISPATCHED'
      and new_value->>'dispatch_proof_fingerprint' = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      and new_value ? 'finance_dispatch_clearance_event_id'
  ),
  1,
  'successful finalization appends high-risk ORDER_DISPATCHED audit bound to proof and clearance'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', 'd8020000-0000-0000-0000-000000000001',
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  (public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000022'::uuid)->>'already_applied')::boolean,
  true,
  'already-dispatched replay is idempotent'
);

select is(
  (public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000023'::uuid)->>'ok')::boolean,
  true,
  'dispatched replay succeeds after Finance clearance was legitimately revoked post-dispatch'
);

select is(
  (public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000023'::uuid)->>'already_applied')::boolean,
  true,
  'dispatched replay after clearance revocation reports already_applied without requiring active clearance'
);

select * from finish();
rollback;
