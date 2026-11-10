-- Contract for migration 20261109103000_order_item_production_completion_authority.sql
-- (order_item_production_completion_authority): governed non-3PCS completion derived from accepted production,
-- partial/shortage/rejection handling, no inflation on replay, immutable events, observe/enforce packed-ready policy.
begin;
select plan(18);

select has_function('public','complete_order_item_from_production_v1',array['uuid','text'],'governed completion RPC exists');
select ok(not has_function_privilege('anon','public.complete_order_item_from_production_v1(uuid,text)','execute')
      and not has_function_privilege('service_role','public.complete_order_item_from_production_v1(uuid,text)','execute'),
  'anon and service_role cannot execute it');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%assert_order_transition_role(''mark_packed_ready'')%',
  'bound to the Operations/Packing authority');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%pg_advisory_xact_lock%',
  'completions are serialised per order item');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%u.is_active IS TRUE%FOR NO KEY UPDATE%'
      and pg_get_functiondef('public.release_order_to_packed_ready_v1(uuid)'::regprocedure) like '%u.is_active is true for no key update%',
  'both operations take revocation-serializing no-key locks without blocking foreign-key reference checks');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%trunc(v_accepted)%'
      and pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%t.product_id = v_item.product_id%'
      and pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%j.order_id = v_item.order_id%',
  'packed units truncate fractional acceptance and reject crossed order/product evidence');
select ok(
  pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure) like '%im.metadata->>''inventory_bucket'' = ''available''%',
  'completion requires canonical inventory receipt provenance in the available bucket');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure)
    like '%NOT (im.metadata ? ''inventory_bucket'')%'
    and pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure)
    like '%im.metadata @> jsonb_build_object(''accepted_qty'', t.accepted_qty)%'
    and pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure)
    like '%lm.metadata->>''position_status'' = ''available''%',
  'legacy receipt fallback requires a reconciled transfer and reconciled accepted quantity');
select ok(not has_any_column_privilege('authenticated','public.production_rgs_transfers','UPDATE')
      and not has_any_column_privilege('authenticated','public.production_rgs_transfers','INSERT'),
  'authenticated staff cannot forge RGS accepted_by/status/accepted_qty directly');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure)
    like '%t.accepted_by IS NOT NULL AND t.accepted_at IS NOT NULL%'
    and pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure)
    like '%t.destination_bin_id IS NULL%OR EXISTS%',
  'unbinned accepted stock is proven by governed RGS actor/time without a staff-insertable movement');
select is((select enforce_packed_ready from public.order_production_evidence_policy), false, 'policy ships in observe mode (no global prohibition of existing direct writes)');
select is(has_table_privilege('authenticated','public.order_item_production_completions','insert'), false, 'clients cannot write completion events directly');
select ok(exists(select 1 from pg_trigger where tgrelid='public.order_items'::regclass
  and tgname='trg_a_order_item_production_qty_freeze' and not tgisinternal),
  'commercial quantity cannot be changed after governed completion evidence exists');
select ok(pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure)
  like '%ORDER_ITEM_COMPLETION_QUANTITY_DRIFT%'
  and pg_get_functiondef('public.complete_order_item_from_production_v1(uuid,text)'::regprocedure)
  like '%ORDER_ITEM_PRODUCTION_STATE_RESTORED%',
  'replays reject historic quantity drift and restore stale packing state');
select ok(exists(select 1 from pg_trigger where tgrelid='public.order_item_production_completions'::regclass and tgname='trg_order_item_production_completions_immutable' and not tgisinternal), 'completion events are append-only');

select lives_ok($macro$
DO $t$
DECLARE
  v_pack uuid := 'c1000000-0000-4000-8000-000000000001';
  v_sales uuid := 'c1000000-0000-4000-8000-000000000002';
  v_owner uuid := 'c1000000-0000-4000-8000-000000000003';
  v_company uuid := 'c1000000-0000-4000-8000-000000000010';
  v_p1 uuid := 'c2000000-0000-4000-8000-000000000001';
  v_p2 uuid := 'c2000000-0000-4000-8000-000000000002';
  v_o1 uuid := 'c3000000-0000-4000-8000-000000000001';
  v_o2 uuid := 'c3000000-0000-4000-8000-000000000002';
  v_o3 uuid := 'c3000000-0000-4000-8000-000000000003';
  v_o4 uuid := 'c3000000-0000-4000-8000-000000000004';
  v_i1 uuid := 'c4000000-0000-4000-8000-000000000001';
  v_i2 uuid := 'c4000000-0000-4000-8000-000000000002';
  v_i3 uuid := 'c4000000-0000-4000-8000-000000000003';
  v_i4 uuid := 'c4000000-0000-4000-8000-000000000004';
  v_i5 uuid := 'c4000000-0000-4000-8000-000000000005';
  v_i6 uuid := 'c4000000-0000-4000-8000-000000000006';
  v_j1 uuid := 'c5000000-0000-4000-8000-000000000001';
  v_jbad_order uuid := 'c5000000-0000-4000-8000-000000000003';
  v_jbad_product uuid := 'c5000000-0000-4000-8000-000000000004';
  v_jbad_transfer uuid := 'c5000000-0000-4000-8000-000000000005';
  v_r jsonb; v_n int; v_status text; v_qty int; v_bad record;
BEGIN
  set local session_replication_role = replica;
  INSERT INTO auth.users(id, email) VALUES (v_pack, 'pc-pack@test.invalid'), (v_sales, 'pc-sales@test.invalid'), (v_owner, 'pc-owner@test.invalid') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.users(id, role, name, is_active) VALUES
    (v_pack, 'PACKING_SUPERVISOR', 'PC Packing', true), (v_sales, 'SALES_EXECUTIVE', 'PC Sales', true),
    (v_owner, 'OWNER', 'PC Owner', true)
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;
  INSERT INTO public.companies(id, business_name, status) VALUES (v_company, 'PC Co', 'active') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.products(id, name, category, sku, hsn_code, production_department) VALUES
    (v_p1, 'PC Product 1', 'sweets', 'PC-P1', '1905', 'arabic_sweets'), (v_p2, 'PC Product 2', 'sweets', 'PC-P2', '1905', 'arabic_sweets')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.orders(id, company_id, order_number, order_origin, tracking_token, status) VALUES
    (v_o1, v_company, 'PC-ORD-1', 'MANUAL', 'pc-ord-1-token', 'in_production'),
    (v_o2, v_company, 'PC-ORD-2', 'MANUAL', 'pc-ord-2-token', 'in_production'),
    (v_o3, v_company, 'PC-ORD-3', 'MANUAL', 'pc-ord-3-token', 'in_production'),
    (v_o4, v_company, 'PC-ORD-4', 'MANUAL', 'pc-ord-4-token', 'in_production') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.order_items(id, order_id, product_id, quantity, production_status) VALUES
    (v_i1, v_o1, v_p1, 10, 'pending'), (v_i2, v_o1, v_p2, 5, 'pending'),
    (v_i3, v_o1, v_p1, 3, 'pending'),
    (v_i4, v_o2, v_p1, 4, 'completed'),
    (v_i5, v_o3, v_p1, 4, 'completed'),
    (v_i6, v_o4, v_p1, 4, 'completed');
  UPDATE public.order_items SET department = '3PCS' WHERE id = v_i3;
  UPDATE public.order_items SET actual_packed_qty = 4 WHERE id IN (v_i4, v_i5, v_i6);
  -- completed job on I1: 6.5 accepted, 1.5 rejected, 2 held;
  -- integer packed quantity must truncate to 6 instead of rounding to 7
  INSERT INTO public.production_jobs(id, order_item_id, order_id, product_id, department, assigned_qty, produced_qty, status, stage, locked)
  VALUES (v_j1, v_i1, v_o1, v_p1, 'ARABIC_SWEETS', 10, 10, 'transferred', 'ready', true);
  INSERT INTO public.production_rgs_transfers(id, job_id, product_id, quantity, status, received_qty, accepted_qty, rejected_qty, hold_qty, sku)
  VALUES ('c6000000-0000-4000-8000-000000000001', v_j1, v_p1, 10, 'partially_accepted', 10, 6.5, 1.5, 2, 'PC-P1');
  -- Mirror an older governed RGS receipt: available, unbinned, no inventory_bucket tag.
  INSERT INTO public.inventory_movements(
    movement_type,product_id,sku,quantity,destination_location,actor_id,
    reason_code,correlation_id,source_document_type,source_document_reference,metadata
  )
  SELECT 'production_receipt_accepted',r.product_id,r.sku,r.accepted_qty,r.destination_store_code,
         v_pack,'rgs_production_acceptance','pc-legacy-available:'||r.id::text,
         'production_rgs_transfer',r.id::text,
         jsonb_build_object('transfer_id',r.id,'job_id',r.job_id,'accepted_qty',r.accepted_qty)
    FROM public.production_rgs_transfers r WHERE r.id = 'c6000000-0000-4000-8000-000000000001'::uuid;
  UPDATE public.production_rgs_transfers
     SET accepted_by=v_pack, accepted_at=statement_timestamp()
   WHERE id = 'c6000000-0000-4000-8000-000000000001'::uuid;
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
  -- A stale token from a demoted but still active user must not retain packing authority.
  UPDATE public.users SET role='SALES_EXECUTIVE' WHERE id=v_pack;
  set local role authenticated;
  BEGIN
    PERFORM public.complete_order_item_from_production_v1(v_i1,'pc-demoted');
    RAISE EXCEPTION 'PC_DEMOTED_USER_ACCEPTED' USING ERRCODE='XX000';
  EXCEPTION WHEN sqlstate 'P0001' THEN
    IF SQLERRM NOT LIKE '%NOT_AUTHORIZED%' THEN RAISE; END IF;
  END;
  RESET ROLE;
  UPDATE public.users SET role='PACKING_SUPERVISOR' WHERE id=v_pack;
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
  -- NEGATIVE: unverified imported/forged unbinned receipt rows with missing
  -- protected accepted_by and accepted_at cannot establish production stock,
  -- irrespective of what an ordinary staff-insertable movement claims.
  -- Genuine quarantine/damaged/expired binned receipts are tested below
  -- against protected RGS-linked lot positions.
  RESET ROLE;
  set local session_replication_role = replica;
  FOR v_bad IN
    SELECT * FROM (VALUES
      (v_i4,v_o2,'quarantine'::text,'c5000000-0000-4000-8000-000000000006'::uuid,'c6000000-0000-4000-8000-000000000006'::uuid),
      (v_i5,v_o3,'damaged'::text,'c5000000-0000-4000-8000-000000000007'::uuid,'c6000000-0000-4000-8000-000000000007'::uuid),
      (v_i6,v_o4,'expired'::text,'c5000000-0000-4000-8000-000000000008'::uuid,'c6000000-0000-4000-8000-000000000008'::uuid)
    ) AS cases(item_id,order_id,bucket,job_id,transfer_id)
  LOOP
    INSERT INTO public.production_jobs(id,order_item_id,order_id,product_id,department,assigned_qty,produced_qty,status,stage,locked)
    VALUES (v_bad.job_id,v_bad.item_id,v_bad.order_id,v_p1,'ARABIC_SWEETS',4,4,'transferred','ready',true);
    INSERT INTO public.production_rgs_transfers(id,job_id,product_id,quantity,status,received_qty,accepted_qty,rejected_qty,hold_qty,sku)
    VALUES (v_bad.transfer_id,v_bad.job_id,v_p1,4,'accepted',4,4,0,0,'PC-P1');
    INSERT INTO public.inventory_movements(
      movement_type,product_id,sku,quantity,destination_location,actor_id,
      reason_code,correlation_id,source_document_type,source_document_reference,metadata
    )
    SELECT 'production_receipt_accepted',r.product_id,r.sku,r.accepted_qty,r.destination_store_code,
           v_pack,'rgs_production_acceptance','pc-unusable:'||r.id::text,
           'production_rgs_transfer',r.id::text,
           jsonb_build_object('transfer_id',r.id,'accepted_qty',r.accepted_qty,'inventory_bucket',v_bad.bucket)
      FROM public.production_rgs_transfers r WHERE r.id = v_bad.transfer_id;
  END LOOP;
  -- These deliberately lack governed RGS actor/timestamp evidence.
  set local session_replication_role = default;
  set local role authenticated;
  FOR v_bad IN
    SELECT * FROM (VALUES
      (v_i4,'quarantine'::text),(v_i5,'damaged'::text),(v_i6,'expired'::text)
    ) AS cases(item_id,bucket)
  LOOP
    BEGIN
      PERFORM public.complete_order_item_from_production_v1(v_bad.item_id,'pc-unusable-'||v_bad.bucket);
      RAISE EXCEPTION 'PC_UNUSABLE_STOCK_PACKED: %',v_bad.bucket USING ERRCODE='XX000';
    EXCEPTION WHEN sqlstate '55000' THEN
      IF SQLERRM NOT LIKE '%ORDER_ITEM_NO_ACCEPTED_STOCK%' THEN RAISE; END IF;
    END;
  END LOOP;
  RESET ROLE;
  IF EXISTS (SELECT 1 FROM public.order_item_production_completions
             WHERE order_item_id IN (v_i4,v_i5,v_i6)) THEN
    RAISE EXCEPTION 'PC_UNUSABLE_STOCK_COMPLETION_SIDE_EFFECT' USING ERRCODE='XX000';
  END IF;
  set local role authenticated;

  -- CodeRabbit cross-guard coverage: even a forged available movement
  -- cannot bypass an expired receipt, unsafe live bin, or identity mismatch.
  -- Separately prove a historical RGS receipt without inventory_bucket remains
  -- eligible when its canonical accepted stock was credited as available.
  RESET ROLE;
  set local session_replication_role = replica;
  INSERT INTO public.b2b_inventory_stores(store_code,store_name,store_type)
  VALUES ('FINISHED_GOODS','PC Finished Goods','finished_goods')
  ON CONFLICT (store_code) DO NOTHING;
  INSERT INTO public.b2b_inventory_bins(
    id,store_code,zone_code,rack_code,shelf_code,bin_code,storage_class
  ) VALUES
    ('c7000000-0000-4000-8000-000000000001','FINISHED_GOODS','PC-Z','PC-R','PC-S','PC-QUAR','quarantine'),
    ('c7000000-0000-4000-8000-000000000002','FINISHED_GOODS','PC-Z','PC-R','PC-S','PC-AVAIL','ambient');
  FOR v_bad IN
    SELECT * FROM (VALUES
      ('legacy'::text,'c3000000-0000-4000-8000-000000000005'::uuid,'c4000000-0000-4000-8000-000000000007'::uuid,'c5000000-0000-4000-8000-000000000009'::uuid,'c6000000-0000-4000-8000-000000000009'::uuid),
      ('past_expiry','c3000000-0000-4000-8000-000000000006'::uuid,'c4000000-0000-4000-8000-000000000008'::uuid,'c5000000-0000-4000-8000-000000000010'::uuid,'c6000000-0000-4000-8000-000000000010'::uuid),
      ('quarantined_bin','c3000000-0000-4000-8000-000000000007'::uuid,'c4000000-0000-4000-8000-000000000009'::uuid,'c5000000-0000-4000-8000-000000000011'::uuid,'c6000000-0000-4000-8000-000000000011'::uuid),
      ('wrong_sku','c3000000-0000-4000-8000-000000000008'::uuid,'c4000000-0000-4000-8000-000000000010'::uuid,'c5000000-0000-4000-8000-000000000012'::uuid,'c6000000-0000-4000-8000-000000000012'::uuid),
      ('wrong_qty','c3000000-0000-4000-8000-000000000009'::uuid,'c4000000-0000-4000-8000-000000000011'::uuid,'c5000000-0000-4000-8000-000000000013'::uuid,'c6000000-0000-4000-8000-000000000013'::uuid),
      ('wrong_location','c3000000-0000-4000-8000-000000000010'::uuid,'c4000000-0000-4000-8000-000000000012'::uuid,'c5000000-0000-4000-8000-000000000014'::uuid,'c6000000-0000-4000-8000-000000000014'::uuid)
    ) AS cases(case_name,order_id,item_id,job_id,transfer_id)
  LOOP
    INSERT INTO public.orders(id,company_id,order_number,order_origin,tracking_token,status)
    VALUES (v_bad.order_id,v_company,'PC-CASE-'||v_bad.case_name,'MANUAL','pc-case-'||v_bad.case_name,'in_production');
    INSERT INTO public.order_items(id,order_id,product_id,quantity,production_status)
    VALUES (v_bad.item_id,v_bad.order_id,v_p1,4,'pending');
    INSERT INTO public.production_jobs(
      id,order_item_id,order_id,product_id,department,assigned_qty,produced_qty,status,stage,locked
    ) VALUES (v_bad.job_id,v_bad.item_id,v_bad.order_id,v_p1,'ARABIC_SWEETS',4,4,'transferred','ready',true);
    INSERT INTO public.production_rgs_transfers(
      id,job_id,product_id,quantity,status,received_qty,accepted_qty,rejected_qty,hold_qty,sku,expiry_date,destination_bin_id
    ) VALUES (
      v_bad.transfer_id,v_bad.job_id,v_p1,4,'accepted',4,4,0,0,'PC-P1',
      CASE WHEN v_bad.case_name='past_expiry' THEN current_date-1 ELSE NULL END,
      CASE WHEN v_bad.case_name='quarantined_bin' THEN 'c7000000-0000-4000-8000-000000000001'::uuid
           WHEN v_bad.case_name IN ('wrong_sku','wrong_qty','wrong_location')
             THEN 'c7000000-0000-4000-8000-000000000002'::uuid
           ELSE NULL END
    );
    INSERT INTO public.inventory_movements(
      movement_type,product_id,sku,quantity,destination_location,actor_id,
      reason_code,correlation_id,source_document_type,source_document_reference,metadata
    ) SELECT
      'production_receipt_accepted',r.product_id,
      CASE WHEN v_bad.case_name='wrong_sku' THEN 'PC-WRONG-SKU' ELSE r.sku END,
      CASE WHEN v_bad.case_name='wrong_qty' THEN 3 ELSE r.accepted_qty END,
      CASE WHEN v_bad.case_name='wrong_location' THEN 'PACKING_ASSEMBLY' ELSE r.destination_store_code END,
      v_pack,'rgs_production_acceptance','pc-extra-receipt:'||r.id::text,
      'production_rgs_transfer',r.id::text,
      CASE WHEN v_bad.case_name='legacy'
        THEN jsonb_build_object('transfer_id',r.id,'accepted_qty',r.accepted_qty)
        ELSE jsonb_build_object('transfer_id',r.id,'accepted_qty',r.accepted_qty,'inventory_bucket','available') END
    FROM public.production_rgs_transfers r WHERE r.id=v_bad.transfer_id;
    -- For identity-mismatch cases, make independently protected RGS lot
    -- evidence valid. Completion must reject the forged movement mismatch,
    -- not merely reject a missing lot or a missing accepted actor.
    IF v_bad.case_name IN ('wrong_sku','wrong_qty','wrong_location') THEN
      INSERT INTO public.inventory_lot_positions
        (product_id,sku,location_code,bin_id,batch_lot,production_rgs_transfer_id,
         available_qty,storage_class,position_status)
      SELECT r.product_id,r.sku,r.destination_store_code,r.destination_bin_id,
             'PC-CROSSGUARD-'||v_bad.case_name,r.id,r.accepted_qty,'ambient','available'
      FROM public.production_rgs_transfers r WHERE r.id=v_bad.transfer_id;
      INSERT INTO public.inventory_movements
        (movement_type,product_id,sku,quantity,destination_location,actor_id,
         correlation_id,metadata)
      SELECT 'lot_position_posted',r.product_id,r.sku,r.accepted_qty,r.destination_store_code,
             v_pack,'pc-crossguard-lot:'||r.id::text,
             jsonb_build_object(
               'production_rgs_transfer_id',r.id,
               'bin_id',r.destination_bin_id,
               'position_status','available',
               'accepted_qty',r.accepted_qty,'hold_qty',r.hold_qty)
      FROM public.production_rgs_transfers r WHERE r.id=v_bad.transfer_id;
    END IF;
  END LOOP;
  UPDATE public.production_rgs_transfers SET accepted_by=v_pack, accepted_at=statement_timestamp()
   WHERE id BETWEEN 'c6000000-0000-4000-8000-000000000009'::uuid
                AND 'c6000000-0000-4000-8000-000000000014'::uuid;
  set local session_replication_role = default;
  set local role authenticated;
  FOR v_bad IN
    SELECT * FROM (VALUES
      ('legacy'::text,'c4000000-0000-4000-8000-000000000007'::uuid),
      ('past_expiry','c4000000-0000-4000-8000-000000000008'::uuid),
      ('quarantined_bin','c4000000-0000-4000-8000-000000000009'::uuid),
      ('wrong_sku','c4000000-0000-4000-8000-000000000010'::uuid),
      ('wrong_qty','c4000000-0000-4000-8000-000000000011'::uuid),
      ('wrong_location','c4000000-0000-4000-8000-000000000012'::uuid)
    ) AS cases(case_name,item_id)
  LOOP
    IF v_bad.case_name = 'legacy' THEN
      v_r := public.complete_order_item_from_production_v1(v_bad.item_id,'pc-legacy-complete');
      IF v_r->>'outcome' IS DISTINCT FROM 'COMPLETE'
         OR (v_r->>'packed_qty')::numeric IS DISTINCT FROM 4 THEN
        RAISE EXCEPTION 'PC_AVAILABLE_LEGACY_RECEIPT_REJECTED %',v_r USING ERRCODE='XX000';
      END IF;
    ELSE
      BEGIN
        PERFORM public.complete_order_item_from_production_v1(v_bad.item_id,'pc-negative-'||v_bad.case_name);
        RAISE EXCEPTION 'PC_RECEIPT_GUARD_BYPASS: %',v_bad.case_name USING ERRCODE='XX000';
      EXCEPTION WHEN sqlstate '55000' THEN
        IF SQLERRM NOT LIKE '%ORDER_ITEM_NO_ACCEPTED_STOCK%' THEN RAISE; END IF;
      END;
    END IF;
  END LOOP;
  RESET ROLE;
  IF (SELECT count(*) FROM public.order_item_production_completions
      WHERE order_item_id IN (
        'c4000000-0000-4000-8000-000000000008',
        'c4000000-0000-4000-8000-000000000009',
        'c4000000-0000-4000-8000-000000000010',
        'c4000000-0000-4000-8000-000000000011',
        'c4000000-0000-4000-8000-000000000012'
      )) <> 0 THEN
    RAISE EXCEPTION 'PC_UNSAFE_RECEIPT_GUARD_SIDE_EFFECT' USING ERRCODE='XX000';
  END IF;
  set local role authenticated;

  -- LEGACY BINNED RGS: old 20260907144005 writer added a receipt movement
  -- WITHOUT inventory_bucket, plus a lot_position_posted movement. Do not
  -- mistake those available receipts for missing stock; require both ledger
  -- evidence and the actual immutable production-transfer lot position.
  RESET ROLE;
  set local session_replication_role = replica;
  INSERT INTO public.b2b_inventory_bins
    (id,store_code,zone_code,rack_code,shelf_code,bin_code,storage_class)
  VALUES
    ('c7000000-0000-4000-8000-000000000002','FINISHED_GOODS','PC-Z','PC-R','PC-S','PC-AVAIL','ambient'),
    ('c7000000-0000-4000-8000-000000000003','FINISHED_GOODS','PC-Z','PC-R','PC-S','PC-DMG','damaged')
  ON CONFLICT (id) DO NOTHING;
  FOR v_bad IN
    SELECT * FROM (VALUES
      ('binned_available'::text,'c3000000-0000-4000-8000-000000000011'::uuid,'c4000000-0000-4000-8000-000000000013'::uuid,'c5000000-0000-4000-8000-000000000015'::uuid,'c6000000-0000-4000-8000-000000000015'::uuid),
      ('binned_missing_lot','c3000000-0000-4000-8000-000000000012'::uuid,'c4000000-0000-4000-8000-000000000014'::uuid,'c5000000-0000-4000-8000-000000000016'::uuid,'c6000000-0000-4000-8000-000000000016'::uuid),
      ('binned_quarantine','c3000000-0000-4000-8000-000000000013'::uuid,'c4000000-0000-4000-8000-000000000015'::uuid,'c5000000-0000-4000-8000-000000000017'::uuid,'c6000000-0000-4000-8000-000000000017'::uuid),
      ('binned_damaged','c3000000-0000-4000-8000-000000000014'::uuid,'c4000000-0000-4000-8000-000000000016'::uuid,'c5000000-0000-4000-8000-000000000018'::uuid,'c6000000-0000-4000-8000-000000000018'::uuid),
      ('binned_expired','c3000000-0000-4000-8000-000000000015'::uuid,'c4000000-0000-4000-8000-000000000017'::uuid,'c5000000-0000-4000-8000-000000000019'::uuid,'c6000000-0000-4000-8000-000000000019'::uuid),
      ('binned_false_lot_status','c3000000-0000-4000-8000-000000000016'::uuid,'c4000000-0000-4000-8000-000000000018'::uuid,'c5000000-0000-4000-8000-000000000020'::uuid,'c6000000-0000-4000-8000-000000000020'::uuid),
      ('binned_missing_lot_movement','c3000000-0000-4000-8000-000000000017'::uuid,'c4000000-0000-4000-8000-000000000019'::uuid,'c5000000-0000-4000-8000-000000000021'::uuid,'c6000000-0000-4000-8000-000000000021'::uuid),
      ('binned_wrong_lot_bin','c3000000-0000-4000-8000-000000000018'::uuid,'c4000000-0000-4000-8000-000000000020'::uuid,'c5000000-0000-4000-8000-000000000022'::uuid,'c6000000-0000-4000-8000-000000000022'::uuid),
      ('binned_malformed_lot_qty','c3000000-0000-4000-8000-000000000019'::uuid,'c4000000-0000-4000-8000-000000000021'::uuid,'c5000000-0000-4000-8000-000000000023'::uuid,'c6000000-0000-4000-8000-000000000023'::uuid)
    ) AS cases(case_name,order_id,item_id,job_id,transfer_id)
  LOOP
    INSERT INTO public.orders(id,company_id,order_number,order_origin,tracking_token,status)
    VALUES (v_bad.order_id,v_company,'PC-'||v_bad.case_name,'MANUAL','pc-'||v_bad.case_name,'in_production');
    INSERT INTO public.order_items(id,order_id,product_id,quantity,production_status)
    VALUES (v_bad.item_id,v_bad.order_id,v_p1,4,'pending');
    INSERT INTO public.production_jobs
      (id,order_item_id,order_id,product_id,department,assigned_qty,produced_qty,status,stage,locked)
    VALUES (v_bad.job_id,v_bad.item_id,v_bad.order_id,v_p1,'ARABIC_SWEETS',4,4,'transferred','ready',true);
    INSERT INTO public.production_rgs_transfers
      (id,job_id,product_id,quantity,status,received_qty,accepted_qty,rejected_qty,hold_qty,sku,
       destination_bin_id,expiry_date)
    VALUES (
      v_bad.transfer_id,v_bad.job_id,v_p1,4,'accepted',4,4,0,0,'PC-P1',
      CASE v_bad.case_name
        WHEN 'binned_quarantine' THEN 'c7000000-0000-4000-8000-000000000001'::uuid
        WHEN 'binned_damaged' THEN 'c7000000-0000-4000-8000-000000000003'::uuid
        ELSE 'c7000000-0000-4000-8000-000000000002'::uuid
      END,
      CASE WHEN v_bad.case_name='binned_expired' THEN current_date-1 ELSE NULL END
    );
    INSERT INTO public.inventory_movements
      (movement_type,product_id,sku,quantity,destination_location,actor_id,reason_code,
       correlation_id,source_document_type,source_document_reference,metadata)
    SELECT 'production_receipt_accepted',r.product_id,r.sku,r.accepted_qty,r.destination_store_code,
       v_pack,'rgs_production_acceptance','pc-binned-receipt:'||r.id::text,
       'production_rgs_transfer',r.id::text,
       jsonb_build_object('transfer_id',r.id,'accepted_qty',r.accepted_qty)
    FROM public.production_rgs_transfers r WHERE r.id=v_bad.transfer_id;
    IF v_bad.case_name <> 'binned_missing_lot' THEN
      INSERT INTO public.inventory_lot_positions
        (product_id,sku,location_code,bin_id,batch_lot,production_rgs_transfer_id,
         available_qty,quarantine_qty,damaged_qty,expired_qty,storage_class,position_status,expiry_date)
      SELECT r.product_id,r.sku,r.destination_store_code,r.destination_bin_id,
        'PC-LOT-'||v_bad.case_name,r.id,
        CASE WHEN v_bad.case_name IN ('binned_quarantine','binned_damaged','binned_expired','binned_false_lot_status') THEN 0 ELSE 4 END,
        CASE WHEN v_bad.case_name IN ('binned_quarantine','binned_false_lot_status') THEN 4 ELSE 0 END,
        CASE WHEN v_bad.case_name='binned_damaged' THEN 4 ELSE 0 END,
        CASE WHEN v_bad.case_name='binned_expired' THEN 4 ELSE 0 END,
        CASE v_bad.case_name WHEN 'binned_quarantine' THEN 'quarantine'
          WHEN 'binned_damaged' THEN 'damaged' ELSE 'ambient' END,
        CASE v_bad.case_name WHEN 'binned_quarantine' THEN 'quarantine'
          WHEN 'binned_damaged' THEN 'damaged' WHEN 'binned_expired' THEN 'expired'
          WHEN 'binned_false_lot_status' THEN 'quarantine' ELSE 'available' END,
        r.expiry_date
      FROM public.production_rgs_transfers r WHERE r.id=v_bad.transfer_id;
    END IF;
    IF v_bad.case_name <> 'binned_missing_lot_movement' THEN
      INSERT INTO public.inventory_movements
        (movement_type,product_id,sku,quantity,destination_location,actor_id,
         correlation_id,metadata)
      SELECT 'lot_position_posted',r.product_id,r.sku,4,r.destination_store_code,
        v_pack,'pc-binned-lot:'||r.id::text,
        jsonb_build_object(
          'production_rgs_transfer_id',r.id,
          'bin_id',CASE WHEN v_bad.case_name='binned_wrong_lot_bin'
            THEN 'c7000000-0000-4000-8000-000000000001'::uuid ELSE r.destination_bin_id END,
          'position_status',CASE v_bad.case_name WHEN 'binned_quarantine' THEN 'quarantine'
            WHEN 'binned_damaged' THEN 'damaged' WHEN 'binned_expired' THEN 'expired'
            WHEN 'binned_false_lot_status' THEN 'quarantine' ELSE 'available' END,
          'accepted_qty',CASE WHEN v_bad.case_name='binned_malformed_lot_qty'
            THEN to_jsonb('not-a-number'::text) ELSE to_jsonb(r.accepted_qty) END,
          'hold_qty',r.hold_qty)
      FROM public.production_rgs_transfers r WHERE r.id=v_bad.transfer_id;
    END IF;
  END LOOP;
  UPDATE public.production_rgs_transfers SET accepted_by=v_pack, accepted_at=statement_timestamp()
   WHERE id BETWEEN 'c6000000-0000-4000-8000-000000000015'::uuid
                AND 'c6000000-0000-4000-8000-000000000023'::uuid;
  set local session_replication_role = default;
  set local role authenticated;
  -- A packing-staff account can INSERT an additional inventory_movement under
  -- the historic staff policy, but cannot alter the RGS-linked lot position.
  -- Deliberately forge an available receipt for the transfer actually recorded
  -- by the authoritative lot position as quarantined. Completion MUST reject.
  INSERT INTO public.inventory_movements(
    movement_type,product_id,sku,quantity,destination_location,actor_id,
    reason_code,correlation_id,source_document_type,source_document_reference,metadata
  )
  SELECT 'production_receipt_accepted',r.product_id,r.sku,r.accepted_qty,r.destination_store_code,
         v_pack,'rgs_production_acceptance','pc-staff-forged-available:'||r.id::text,
         'production_rgs_transfer',r.id::text,
         jsonb_build_object('transfer_id',r.id,'accepted_qty',r.accepted_qty,'inventory_bucket','available')
    FROM public.production_rgs_transfers r
   WHERE r.id='c6000000-0000-4000-8000-000000000020'::uuid;
  FOR v_bad IN
    SELECT * FROM (VALUES
      ('binned_available'::text,'c4000000-0000-4000-8000-000000000013'::uuid),
      ('binned_missing_lot','c4000000-0000-4000-8000-000000000014'::uuid),
      ('binned_quarantine','c4000000-0000-4000-8000-000000000015'::uuid),
      ('binned_damaged','c4000000-0000-4000-8000-000000000016'::uuid),
      ('binned_expired','c4000000-0000-4000-8000-000000000017'::uuid),
      ('binned_false_lot_status','c4000000-0000-4000-8000-000000000018'::uuid),
      ('binned_missing_lot_movement','c4000000-0000-4000-8000-000000000019'::uuid),
      ('binned_wrong_lot_bin','c4000000-0000-4000-8000-000000000020'::uuid),
      ('binned_malformed_lot_qty','c4000000-0000-4000-8000-000000000021'::uuid)
    ) AS cases(case_name,item_id)
  LOOP
    IF v_bad.case_name = 'binned_available' THEN
      v_r := public.complete_order_item_from_production_v1(v_bad.item_id,'pc-binned-available');
      IF v_r->>'outcome' IS DISTINCT FROM 'COMPLETE'
         OR (v_r->>'packed_qty')::numeric IS DISTINCT FROM 4 THEN
        RAISE EXCEPTION 'PC_VALID_BINNED_LEGACY_DENIED %',v_r USING ERRCODE='XX000';
      END IF;
    ELSE
      BEGIN
        PERFORM public.complete_order_item_from_production_v1(v_bad.item_id,'pc-binned-negative-'||v_bad.case_name);
        RAISE EXCEPTION 'PC_UNSAFE_LEGACY_BIN_ALLOWED %',v_bad.case_name USING ERRCODE='XX000';
      EXCEPTION WHEN sqlstate '55000' THEN
        IF SQLERRM NOT LIKE '%ORDER_ITEM_NO_ACCEPTED_STOCK%' THEN RAISE; END IF;
      END;
    END IF;
  END LOOP;
  RESET ROLE;
  IF (SELECT count(*) FROM public.order_item_production_completions
       WHERE order_item_id IN (
         'c4000000-0000-4000-8000-000000000014',
         'c4000000-0000-4000-8000-000000000015',
         'c4000000-0000-4000-8000-000000000016',
         'c4000000-0000-4000-8000-000000000017',
         'c4000000-0000-4000-8000-000000000018',
         'c4000000-0000-4000-8000-000000000019',
         'c4000000-0000-4000-8000-000000000020',
         'c4000000-0000-4000-8000-000000000021'
       )) <> 0 THEN
    RAISE EXCEPTION 'PC_UNSAFE_LEGACY_BIN_CREATED_COMPLETION' USING ERRCODE='XX000';
  END IF;
  set local role authenticated;

  -- UNBINNED provenance hardening: no authenticated staff-created movement
  -- may manufacture a governed RGS acceptance. Current and historic canonical
  -- unbinned RGS writers credited accepted_qty to AVAILABLE; their protected
  -- actor/timestamp and accepted transfer state are the authority, NOT a
  -- forged available-bucket metadata row.
  RESET ROLE;
  set local session_replication_role = replica;
  FOR v_bad IN
    SELECT * FROM (VALUES
      ('unbinned_governed'::text,'c3000000-0000-4000-8000-000000000020'::uuid,
        'c4000000-0000-4000-8000-000000000022'::uuid,
        'c5000000-0000-4000-8000-000000000024'::uuid,
        'c6000000-0000-4000-8000-000000000024'::uuid),
      ('unbinned_unverified','c3000000-0000-4000-8000-000000000021'::uuid,
        'c4000000-0000-4000-8000-000000000023'::uuid,
        'c5000000-0000-4000-8000-000000000025'::uuid,
        'c6000000-0000-4000-8000-000000000025'::uuid)
    ) AS cases(case_name,order_id,item_id,job_id,transfer_id)
  LOOP
    INSERT INTO public.orders(id,company_id,order_number,order_origin,tracking_token,status)
    VALUES(v_bad.order_id,v_company,'PC-'||v_bad.case_name,'MANUAL',
           'pc-'||v_bad.case_name,'in_production');
    INSERT INTO public.order_items(id,order_id,product_id,quantity,production_status)
    VALUES(v_bad.item_id,v_bad.order_id,v_p1,4,'pending');
    INSERT INTO public.production_jobs
      (id,order_item_id,order_id,product_id,department,assigned_qty,produced_qty,status,stage,locked)
    VALUES(v_bad.job_id,v_bad.item_id,v_bad.order_id,v_p1,'ARABIC_SWEETS',4,4,'transferred','ready',true);
    INSERT INTO public.production_rgs_transfers
      (id,job_id,product_id,quantity,status,received_qty,accepted_qty,rejected_qty,hold_qty,sku,
       accepted_by,accepted_at)
    VALUES(v_bad.transfer_id,v_bad.job_id,v_p1,4,'accepted',4,4,0,0,'PC-P1',
      CASE WHEN v_bad.case_name='unbinned_governed' THEN v_pack ELSE NULL END,
      CASE WHEN v_bad.case_name='unbinned_governed' THEN statement_timestamp() ELSE NULL END);
  END LOOP;
  set local session_replication_role = default;
  set local role authenticated;
  -- This forged receipt is INSERTed as authenticated packing staff under the
  -- actual legacy inventory_movements RLS policy. It must confer no authority
  -- on the unverified RGS transfer even though metadata claims 'available'.
  INSERT INTO public.inventory_movements
    (movement_type,product_id,sku,quantity,destination_location,actor_id,
     reason_code,correlation_id,source_document_type,source_document_reference,metadata)
  SELECT 'production_receipt_accepted',r.product_id,r.sku,r.accepted_qty,r.destination_store_code,
    v_pack,'rgs_production_acceptance','pc-forged-unbinned:'||r.id::text,
    'production_rgs_transfer',r.id::text,
    jsonb_build_object('transfer_id',r.id,'accepted_qty',r.accepted_qty,'inventory_bucket','available')
  FROM public.production_rgs_transfers r
  WHERE r.id='c6000000-0000-4000-8000-000000000025'::uuid;
  -- The trusted transfer is sufficient: no receipt-movement row is needed.
  v_r := public.complete_order_item_from_production_v1(
    'c4000000-0000-4000-8000-000000000022'::uuid,'pc-trusted-unbinned');
  IF v_r->>'outcome' IS DISTINCT FROM 'COMPLETE'
     OR (v_r->>'packed_qty')::numeric IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'PC_VALID_UNBINNED_ACCEPTANCE_DENIED %',v_r USING ERRCODE='XX000';
  END IF;
  BEGIN
    PERFORM public.complete_order_item_from_production_v1(
      'c4000000-0000-4000-8000-000000000023'::uuid,'pc-forged-unbinned');
    RAISE EXCEPTION 'PC_FORGED_UNBINNED_MOVEMENT_ACCEPTED' USING ERRCODE='XX000';
  EXCEPTION WHEN sqlstate '55000' THEN
    IF SQLERRM NOT LIKE '%ORDER_ITEM_NO_ACCEPTED_STOCK%' THEN RAISE; END IF;
  END;
  RESET ROLE;
  IF EXISTS (
    SELECT 1 FROM public.order_item_production_completions
     WHERE order_item_id='c4000000-0000-4000-8000-000000000023'::uuid
  ) THEN
    RAISE EXCEPTION 'PC_FORGED_UNBINNED_MOVEMENT_SIDE_EFFECT' USING ERRCODE='XX000';
  END IF;
  set local role authenticated;

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
  -- Once a governed partial completion is recorded, even a commercial
  -- quantity change must be explicitly rejected instead of leaving stale evidence.
  RESET ROLE;
  BEGIN
    UPDATE public.order_items SET quantity=6 WHERE id=v_i1;
    RAISE EXCEPTION 'PC_QUANTITY_AMENDMENT_ALLOWED' USING ERRCODE='XX000';
  EXCEPTION WHEN sqlstate '55000' THEN
    IF SQLERRM NOT LIKE '%ORDER_ITEM_PRODUCTION_QUANTITY_FROZEN%' THEN RAISE; END IF;
  END;
  set local role authenticated;
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
  -- Mirror canonical RGS receipt evidence for this positive fixture.
  INSERT INTO public.inventory_movements(
    movement_type,product_id,sku,quantity,destination_location,actor_id,
    reason_code,correlation_id,source_document_type,source_document_reference,metadata
  )
  SELECT 'production_receipt_accepted',r.product_id,r.sku,r.accepted_qty,r.destination_store_code,
         v_pack,'rgs_production_acceptance','pc-available:'||r.id::text,
         'production_rgs_transfer',r.id::text,
         jsonb_build_object('transfer_id',r.id,'accepted_qty',r.accepted_qty,'inventory_bucket','available')
    FROM public.production_rgs_transfers r WHERE r.id = 'c6000000-0000-4000-8000-000000000002'::uuid;
  UPDATE public.production_rgs_transfers
     SET accepted_by=v_pack, accepted_at=statement_timestamp()
   WHERE id = 'c6000000-0000-4000-8000-000000000002'::uuid;
  set local session_replication_role = default;
  set local role authenticated;
  v_r := public.complete_order_item_from_production_v1(v_i1, 'pc-c2');
  IF v_r->>'outcome' <> 'COMPLETE' OR (v_r->>'packed_qty')::numeric <> 10 THEN RAISE EXCEPTION 'PC_COMPLETE_WRONG %', v_r; END IF;
  v_r := public.complete_order_item_from_production_v1(v_i1, 'pc-c3');
  SELECT actual_packed_qty INTO v_qty FROM public.order_items WHERE id = v_i1;
  IF v_qty <> 10 THEN RAISE EXCEPTION 'PC_INFLATED %', v_qty; END IF;
  -- Direct alteration of completion status/packed quantity may still occur
  -- during observe mode. A replay must restore current accepted truth.
  RESET ROLE;
  UPDATE public.order_items SET production_status='pending',actual_packed_qty=0 WHERE id=v_i1;
  set local role authenticated;
  v_r := public.complete_order_item_from_production_v1(v_i1,'pc-restore-state');
  IF NOT coalesce((v_r->>'row_repaired')::boolean,false) THEN
    RAISE EXCEPTION 'PC_STALE_PACKED_STATE_NOT_REPAIRED %', v_r;
  END IF;
  SELECT production_status,actual_packed_qty INTO v_status,v_qty FROM public.order_items WHERE id=v_i1;
  IF v_status<>'completed' OR v_qty<>10 THEN
    RAISE EXCEPTION 'PC_REPAIRED_STATE_INVALID % %',v_status,v_qty;
  END IF;
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

  -- Active OWNER retains an explicitly authorized packing route even though
  -- is_staff_role deliberately excludes OWNER; deactivated OWNER is denied.
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_owner::text,'role','authenticated','aal','aal1')::text,true);
  v_r := public.release_order_to_packed_ready_v1(v_o4);
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'PC_ACTIVE_OWNER_DENIED %',v_r; END IF;
  RESET ROLE;
  UPDATE public.users SET is_active=false WHERE id=v_owner;
  set local role authenticated;
  BEGIN
    PERFORM public.release_order_to_packed_ready_v1(v_o4);
    RAISE EXCEPTION 'PC_INACTIVE_OWNER_ALLOWED' USING ERRCODE='XX000';
  EXCEPTION WHEN sqlstate '42501' THEN
    IF SQLERRM NOT LIKE '%PACKED_READY_ACTOR_INACTIVE%' THEN RAISE; END IF;
  END;
  RESET ROLE;
  UPDATE public.users SET is_active=true WHERE id=v_owner;
  set local role authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_pack::text,'role','authenticated','aal','aal1')::text,true);
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
