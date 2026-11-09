-- Contract for migration 20261109103000_order_item_production_completion_authority.sql
-- (order_item_production_completion_authority): governed non-3PCS completion derived from accepted production,
-- partial/shortage/rejection handling, no inflation on replay, immutable events, observe/enforce packed-ready policy.
begin;
select plan(12);

select has_function('public','complete_order_item_from_production_v1',array['uuid','text'],'governed completion RPC exists');
select ok(not has_function_privilege('anon','public.complete_order_item_from_production_v1(uuid,text)','execute')
      and not has_function_privilege('service_role','public.complete_order_item_from_production_v1(uuid,text)','execute'),
  'anon and service_role cannot execute it');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%assert_order_transition_role(''mark_packed_ready'')%',
  'bound to the Operations/Packing authority');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%pg_advisory_xact_lock%',
  'completions are serialised per order item');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%public.is_internal_staff(auth.uid())%'
      and pg_get_functiondef('public.release_order_to_packed_ready_v1(uuid)'::regprocedure) like '%public.is_internal_staff(auth.uid())%',
  'both operations revalidate active staff');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%trunc(v_accepted)%'
      and pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%t.product_id = v_item.product_id%'
      and pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%j.order_id = v_item.order_id%',
  'packed units truncate fractional acceptance and reject crossed order/product evidence');
select is((select enforce_packed_ready from public.order_production_evidence_policy), false, 'policy ships in observe mode (no global prohibition of existing direct writes)');
select is(has_table_privilege('authenticated','public.order_item_production_completions','insert'), false, 'clients cannot write completion events directly');
select ok(exists(select 1 from pg_trigger where tgrelid='public.order_item_production_completions'::regclass and tgname='trg_order_item_production_completions_immutable' and not tgisinternal), 'completion events are append-only');

select lives_ok($macro$
DO $t$
DECLARE
  v_pack uuid := 'c1000000-0000-4000-8000-000000000001';
  v_sales uuid := 'c1000000-0000-4000-8000-000000000002';
  v_company uuid := 'c1000000-0000-4000-8000-000000000010';
  v_p1 uuid := 'c2000000-0000-4000-8000-000000000001';
  v_p2 uuid := 'c2000000-0000-4000-8000-000000000002';
  v_o1 uuid := 'c3000000-0000-4000-8000-000000000001';
  v_o2 uuid := 'c3000000-0000-4000-8000-000000000002';
  v_o3 uuid := 'c3000000-0000-4000-8000-000000000003';
  v_i1 uuid := 'c4000000-0000-4000-8000-000000000001';
  v_i2 uuid := 'c4000000-0000-4000-8000-000000000002';
  v_i3 uuid := 'c4000000-0000-4000-8000-000000000003';
  v_i4 uuid := 'c4000000-0000-4000-8000-000000000004';
  v_i5 uuid := 'c4000000-0000-4000-8000-000000000005';
  v_j1 uuid := 'c5000000-0000-4000-8000-000000000001';
  v_jbad_order uuid := 'c5000000-0000-4000-8000-000000000003';
  v_jbad_product uuid := 'c5000000-0000-4000-8000-000000000004';
  v_jbad_transfer uuid := 'c5000000-0000-4000-8000-000000000005';
  v_r jsonb; v_n int; v_status text; v_qty int;
BEGIN
  set local session_replication_role = replica;
  INSERT INTO auth.users(id, email) VALUES (v_pack, 'pc-pack@test.invalid'), (v_sales, 'pc-sales@test.invalid') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.users(id, role, name, is_active) VALUES
    (v_pack, 'PACKING_SUPERVISOR', 'PC Packing', true), (v_sales, 'SALES_EXECUTIVE', 'PC Sales', true)
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;
  INSERT INTO public.companies(id, business_name, status) VALUES (v_company, 'PC Co', 'active') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.products(id, name, category, sku, hsn_code, production_department) VALUES
    (v_p1, 'PC Product 1', 'sweets', 'PC-P1', '1905', 'arabic_sweets'), (v_p2, 'PC Product 2', 'sweets', 'PC-P2', '1905', 'arabic_sweets')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.orders(id, company_id, order_number, order_origin, tracking_token, status) VALUES
    (v_o1, v_company, 'PC-ORD-1', 'MANUAL', 'pc-ord-1-token', 'in_production'),
    (v_o2, v_company, 'PC-ORD-2', 'MANUAL', 'pc-ord-2-token', 'in_production'),
    (v_o3, v_company, 'PC-ORD-3', 'MANUAL', 'pc-ord-3-token', 'in_production') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.order_items(id, order_id, product_id, quantity, production_status) VALUES
    (v_i1, v_o1, v_p1, 10, 'pending'), (v_i2, v_o1, v_p2, 5, 'pending'),
    (v_i3, v_o1, v_p1, 3, 'pending'),
    (v_i4, v_o2, v_p1, 4, 'completed'),
    (v_i5, v_o3, v_p1, 4, 'completed');
  UPDATE public.order_items SET department = '3PCS' WHERE id = v_i3;
  UPDATE public.order_items SET actual_packed_qty = 4 WHERE id IN (v_i4, v_i5);
  -- completed job on I1: 6.5 accepted, 1.5 rejected, 2 held;
  -- integer packed quantity must truncate to 6 instead of rounding to 7
  INSERT INTO public.production_jobs(id, order_item_id, order_id, product_id, department, assigned_qty, produced_qty, status, stage, locked)
  VALUES (v_j1, v_i1, v_o1, v_p1, 'ARABIC_SWEETS', 10, 10, 'transferred', 'ready', true);
  INSERT INTO public.production_rgs_transfers(id, job_id, product_id, quantity, status, received_qty, accepted_qty, rejected_qty, hold_qty, sku)
  VALUES ('c6000000-0000-4000-8000-000000000001', v_j1, v_p1, 10, 'partially_accepted', 10, 6.5, 1.5, 2, 'PC-P1');
  set local session_replication_role = default;

  -- NEGATIVE: non-Operations role
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_sales::text, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  set local role authenticated;
  BEGIN
    PERFORM public.complete_order_item_from_production_v1(v_i1, 'pc-sales');
    RAISE EXCEPTION 'PC_SALES_NOT_REJECTED' USING ERRCODE = 'XX000';
  EXCEPTION WHEN sqlstate 'P0001' THEN
    IF SQLERRM NOT LIKE '%NOT_AUTHORIZED%' THEN RAISE; END IF;
  END;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_pack::text, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  RESET ROLE;
  UPDATE public.users SET is_active=false WHERE id=v_pack;
  set local role authenticated;
  BEGIN
    PERFORM public.complete_order_item_from_production_v1(v_i1,'pc-revoked');
    RAISE EXCEPTION 'PC_REVOKED_USER_ACCEPTED' USING ERRCODE='XX000';
  EXCEPTION WHEN sqlstate '42501' THEN
    IF SQLERRM NOT LIKE '%ORDER_ITEM_COMPLETION_STAFF_INACTIVE%' THEN RAISE; END IF;
  END;
  RESET ROLE;
  UPDATE public.users SET is_active=true WHERE id=v_pack;
  set local role authenticated;
  -- NEGATIVE: line without any bound production
  BEGIN
    PERFORM public.complete_order_item_from_production_v1(v_i2, 'pc-noevidence');
    RAISE EXCEPTION 'PC_NO_EVIDENCE_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '55000' THEN NULL; END;
  -- A wrongly attributed production job must never count for another line.
  RESET ROLE;
  set local session_replication_role = replica;
  INSERT INTO public.production_jobs(id,order_item_id,order_id,product_id,department,assigned_qty,produced_qty,status,stage,locked)
  VALUES (v_jbad_order,v_i2,v_o2,v_p2,'ARABIC_SWEETS',5,5,'transferred','ready',true),
         (v_jbad_product,v_i2,v_o1,v_p1,'ARABIC_SWEETS',5,5,'transferred','ready',true);
  INSERT INTO public.production_rgs_transfers(id,job_id,product_id,quantity,status,received_qty,accepted_qty,rejected_qty,hold_qty,sku)
  VALUES ('c6000000-0000-4000-8000-000000000003',v_jbad_order,v_p2,5,'accepted',5,5,0,0,'PC-P2'),
         ('c6000000-0000-4000-8000-000000000004',v_jbad_product,v_p1,5,'accepted',5,5,0,0,'PC-P1');
  set local session_replication_role = default;
  set local role authenticated;
  BEGIN
    PERFORM public.complete_order_item_from_production_v1(v_i2,'pc-wrong-job');
    RAISE EXCEPTION 'PC_WRONG_JOB_ACCEPTED' USING ERRCODE='XX000';
  EXCEPTION WHEN sqlstate '55000' THEN
    IF SQLERRM NOT LIKE '%ORDER_ITEM_NO_PRODUCTION_EVIDENCE%' THEN RAISE; END IF;
  END;
  RESET ROLE;
  set local session_replication_role = replica;
  INSERT INTO public.production_jobs(id,order_item_id,order_id,product_id,department,assigned_qty,produced_qty,status,stage,locked)
  VALUES (v_jbad_transfer,v_i2,v_o1,v_p2,'ARABIC_SWEETS',5,5,'transferred','ready',true);
  INSERT INTO public.production_rgs_transfers(id,job_id,product_id,quantity,status,received_qty,accepted_qty,rejected_qty,hold_qty,sku)
  VALUES ('c6000000-0000-4000-8000-000000000005',v_jbad_transfer,v_p1,5,'accepted',5,5,0,0,'PC-P1');
  set local session_replication_role = default;
  set local role authenticated;
  BEGIN
    PERFORM public.complete_order_item_from_production_v1(v_i2,'pc-wrong-rgs-product');
    RAISE EXCEPTION 'PC_WRONG_RGS_PRODUCT_ACCEPTED' USING ERRCODE='XX000';
  EXCEPTION WHEN sqlstate '55000' THEN
    IF SQLERRM NOT LIKE '%ORDER_ITEM_NO_ACCEPTED_STOCK%' THEN RAISE; END IF;
  END;
  -- NEGATIVE: 3PCS items keep their own governed completion
  BEGIN
    PERFORM public.complete_order_item_from_production_v1(v_i3, 'pc-3pcs');
    RAISE EXCEPTION 'PC_3PCS_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '55000' THEN NULL; END;

  -- PARTIAL: only accepted stock counts (6 of 10); rejected and held quantities cannot be packed
  v_r := public.complete_order_item_from_production_v1(v_i1, 'pc-c1');
  IF v_r->>'outcome' <> 'PARTIAL' OR (v_r->>'packed_qty')::numeric <> 6 THEN RAISE EXCEPTION 'PC_PARTIAL_WRONG %', v_r; END IF;
  IF (v_r->'evidence'->>'accepted_qty_total')::numeric <> 6.5 THEN
    RAISE EXCEPTION 'PC_ACCEPTED_EVIDENCE_MISMATCH %', v_r;
  END IF;
  SELECT production_status, actual_packed_qty INTO v_status, v_qty FROM public.order_items WHERE id = v_i1;
  IF v_status <> 'partial_ready' OR v_qty <> 6 THEN RAISE EXCEPTION 'PC_PARTIAL_ROW_WRONG % %', v_status, v_qty; END IF;
  -- packed-ready stays blocked while the line is partial
  v_r := public.release_order_to_packed_ready_v1(v_o1);
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'PC_PARTIAL_PACKED_READY_ALLOWED'; END IF;

  -- REPLAY: same correlation id is idempotent; a new id with no new evidence is a no-op (no second event)
  v_r := public.complete_order_item_from_production_v1(v_i1, 'pc-c1');
  IF NOT (v_r->>'already_recorded')::boolean THEN RAISE EXCEPTION 'PC_REPLAY_NOT_IDEMPOTENT'; END IF;
  v_r := public.complete_order_item_from_production_v1(v_i1, 'pc-c1b');
  IF NOT (v_r->>'already_current')::boolean THEN RAISE EXCEPTION 'PC_NO_NEW_EVIDENCE_NOT_NOOP'; END IF;
  SELECT count(*) INTO v_n FROM public.order_item_production_completions WHERE order_item_id = v_i1;
  IF v_n <> 1 THEN RAISE EXCEPTION 'PC_DUPLICATE_EVENT %', v_n; END IF;

  -- COMPLETE: remaining production is accepted later; packed quantity is capped at the ordered quantity
  RESET ROLE;
  set local session_replication_role = replica;
  INSERT INTO public.production_jobs(id, order_item_id, order_id, product_id, department, assigned_qty, produced_qty, status, stage, locked)
  VALUES ('c5000000-0000-4000-8000-000000000002', v_i1, v_o1, v_p1, 'ARABIC_SWEETS', 8, 8, 'transferred', 'ready', true);
  INSERT INTO public.production_rgs_transfers(id, job_id, product_id, quantity, status, received_qty, accepted_qty, rejected_qty, hold_qty, sku)
  VALUES ('c6000000-0000-4000-8000-000000000002', 'c5000000-0000-4000-8000-000000000002', v_p1, 8, 'accepted', 8, 8, 0, 0, 'PC-P1');
  set local session_replication_role = default;
  set local role authenticated;
  v_r := public.complete_order_item_from_production_v1(v_i1, 'pc-c2');
  IF v_r->>'outcome' <> 'COMPLETE' OR (v_r->>'packed_qty')::numeric <> 10 THEN RAISE EXCEPTION 'PC_COMPLETE_WRONG %', v_r; END IF;
  v_r := public.complete_order_item_from_production_v1(v_i1, 'pc-c3');
  SELECT actual_packed_qty INTO v_qty FROM public.order_items WHERE id = v_i1;
  IF v_qty <> 10 THEN RAISE EXCEPTION 'PC_INFLATED %', v_qty; END IF;
  -- audit_logs is not readable by the client role; inspect it as the owner
  RESET ROLE;
  SELECT count(*) INTO v_n FROM public.audit_logs WHERE entity_id = v_i1::text AND action_type IN ('ORDER_ITEM_PRODUCTION_COMPLETED','ORDER_ITEM_PRODUCTION_PARTIAL');
  IF v_n <> 2 THEN RAISE EXCEPTION 'PC_AUDIT_COUNT %', v_n; END IF;
  set local role authenticated;

  -- OBSERVE mode: a direct-write claim still reaches packed_ready but is audited
  v_r := public.release_order_to_packed_ready_v1(v_o2);
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'PC_OBSERVE_BLOCKED %', v_r; END IF;
  RESET ROLE;
  SELECT count(*) INTO v_n FROM public.audit_logs WHERE entity_id = v_o2::text AND action_type = 'PACKED_READY_WITHOUT_GOVERNED_PRODUCTION_EVIDENCE';
  IF v_n <> 1 THEN RAISE EXCEPTION 'PC_OBSERVE_NOT_AUDITED'; END IF;
  set local role authenticated;

  -- ENFORCE mode (set by the owner, never by a client): unsupported claim is blocked; governed completion passes
  RESET ROLE;
  set local session_replication_role = replica;
  UPDATE public.order_production_evidence_policy SET enforce_packed_ready = true;
  set local session_replication_role = default;
  set local role authenticated;
  v_r := public.release_order_to_packed_ready_v1(v_o3);
  IF (v_r->>'ok')::boolean OR NOT (v_r->'blockers') @> '[{"code":"production_completion_unsupported"}]'::jsonb THEN
    RAISE EXCEPTION 'PC_ENFORCE_NOT_BLOCKING %', v_r;
  END IF;
  -- events are immutable even for the owner
  RESET ROLE;
  BEGIN
    UPDATE public.order_item_production_completions SET packed_qty = 99 WHERE order_item_id = v_i1;
    RAISE EXCEPTION 'PC_EVENT_MUTABLE';
  EXCEPTION WHEN sqlstate '42501' THEN NULL; END;
END
$t$;
$macro$, 'governed completion: authorization, evidence binding, partial/shortage, replay, no inflation, audit, observe and enforce policy');

select ok(exists(select 1 from pg_policies where schemaname='public' and tablename='order_item_production_completions'), 'completion events have an internal-staff read policy only');
select ok(pg_get_functiondef('public.release_order_to_packed_ready_v1(uuid)'::regprocedure) like '%production_completion_unsupported%', 'packed-ready consults the production evidence policy');
select * from finish();
rollback;
