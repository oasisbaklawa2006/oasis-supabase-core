-- Phase 4 completion: stock is unavailable until GRN finalisation, discrepancies
-- are governed, reversals are compensating ledger entries, and gate/store state
-- is exposed through a security-invoker reconciliation view.

ALTER FUNCTION public.accept_b2b_inventory_receipt(uuid, jsonb, text)
  RENAME TO accept_b2b_inventory_receipt_phase3_posting;

ALTER TABLE public.b2b_inventory_grns
  ADD COLUMN stock_posted_at timestamptz NULL,
  ADD COLUMN stock_posted_by uuid NULL REFERENCES public.users(id) ON DELETE RESTRICT;

ALTER TABLE public.b2b_inventory_grns
  DROP CONSTRAINT b2b_inventory_grns_receipt_id_key;
CREATE UNIQUE INDEX uq_b2b_inventory_grns_open_receipt
  ON public.b2b_inventory_grns(receipt_id)
  WHERE status IN ('draft','finalised');
CREATE UNIQUE INDEX uq_b2b_inventory_grns_single_reversal
  ON public.b2b_inventory_grns(reversal_grn_id)
  WHERE reversal_grn_id IS NOT NULL;

CREATE TABLE public.b2b_inventory_store_assignments (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  store_code text NOT NULL REFERENCES public.b2b_inventory_stores(store_code) ON DELETE RESTRICT,
  authority text NOT NULL CHECK (authority IN ('receive','manage')),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  assigned_by uuid NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  PRIMARY KEY (user_id,store_code)
);
ALTER TABLE public.b2b_inventory_store_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Inventory managers read store assignments" ON public.b2b_inventory_store_assignments
  FOR SELECT TO authenticated USING (public.can_manage_b2b_inventory((select auth.uid())));
CREATE POLICY "Inventory managers maintain store assignments" ON public.b2b_inventory_store_assignments
  FOR ALL TO authenticated USING (public.can_manage_b2b_inventory((select auth.uid())))
  WITH CHECK (public.can_manage_b2b_inventory((select auth.uid())));
REVOKE ALL ON public.b2b_inventory_store_assignments FROM anon;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.b2b_inventory_store_assignments TO authenticated;

CREATE OR REPLACE FUNCTION public.can_access_b2b_inventory_store(
  p_user_id uuid,p_store_code text,p_required_authority text
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.id=p_user_id AND upper(coalesce(u.role,''))
    IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','INVENTORY_MANAGER'))
  OR EXISTS (SELECT 1 FROM public.b2b_inventory_store_assignments a
    WHERE a.user_id=p_user_id AND a.store_code=p_store_code
      AND (p_required_authority='receive' OR a.authority='manage'));
$$;
REVOKE ALL ON FUNCTION public.can_access_b2b_inventory_store(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_access_b2b_inventory_store(uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.accept_b2b_inventory_receipt(
  p_receipt_id uuid, p_lines jsonb, p_correlation_id text
) RETURNS public.b2b_inventory_receipts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_group record;
  v_line public.b2b_inventory_receipt_lines%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.can_receive_b2b_inventory(v_actor) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;

  -- Reuse the Phase 3 disposition validation, then immediately move accepted
  -- quantity out of available stock until physical put-away and GRN finalisation.
  v_receipt := public.accept_b2b_inventory_receipt_phase3_posting(
    p_receipt_id, p_lines, p_correlation_id
  );
  IF NOT public.can_access_b2b_inventory_store(v_actor,v_receipt.destination_store_code,'receive') THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;

  FOR v_group IN
    SELECT product_id, sku, sum(accepted_qty) AS qty
    FROM public.b2b_inventory_receipt_lines
    WHERE receipt_id=p_receipt_id AND accepted_qty>0
    GROUP BY product_id, sku
  LOOP
    UPDATE public.inventory_stock_balances
    SET available_qty=available_qty-v_group.qty, version=version+1, updated_at=now()
    WHERE product_id=v_group.product_id AND sku=v_group.sku
      AND location_code=v_receipt.destination_store_code
      AND available_qty>=v_group.qty;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unable to hold accepted stock before GRN'; END IF;
  END LOOP;

  FOR v_line IN
    SELECT * FROM public.b2b_inventory_receipt_lines
    WHERE receipt_id=p_receipt_id AND accepted_qty>0 ORDER BY id
  LOOP
    INSERT INTO public.inventory_movements(
      movement_type, product_id, sku, quantity, source_location, actor_id,
      reason_code, correlation_id, source_document_type,
      source_document_reference, batch_lot, expiry_date, metadata
    ) VALUES (
      'inventory_hold', v_line.product_id, v_line.sku, v_line.accepted_qty,
      v_receipt.destination_store_code, v_actor, 'awaiting_putaway_grn',
      p_correlation_id || ':grn-hold:' || v_line.id,
      v_receipt.source_document_type, v_receipt.source_document_reference,
      coalesce(v_line.oasis_batch_lot,v_line.supplier_batch_lot), v_line.expiry_date,
      jsonb_build_object('receipt_id',p_receipt_id,'receipt_line_id',v_line.id)
    );
  END LOOP;

  INSERT INTO public.b2b_supplier_discrepancies(
    receipt_line_id, discrepancy_type, quantity, evidence
  )
  SELECT l.id, d.kind, d.qty, jsonb_build_array(jsonb_build_object(
      'source','receipt_disposition','receipt_id',p_receipt_id,'recorded_at',now()))
  FROM public.b2b_inventory_receipt_lines l
  CROSS JOIN LATERAL (VALUES
    ('short'::text,l.shortage_qty),('excess',l.excess_qty),
    ('damaged',l.damaged_qty),('rejected',l.rejected_qty)
  ) d(kind,qty)
  WHERE l.receipt_id=p_receipt_id AND d.qty>0
    AND NOT EXISTS (SELECT 1 FROM public.b2b_supplier_discrepancies x
      WHERE x.receipt_line_id=l.id AND x.discrepancy_type=d.kind
        AND x.status NOT IN ('resolved','waived'));

  RETURN v_receipt;
END $$;

CREATE OR REPLACE FUNCTION public.finalise_b2b_inventory_grn(
  p_receipt_id uuid, p_grn_number text, p_correlation_id text
) RETURNS public.b2b_inventory_grns
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor uuid:=auth.uid();
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_grn public.b2b_inventory_grns%ROWTYPE;
  v_group record;
  v_line public.b2b_inventory_receipt_lines%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_b2b_inventory(v_actor) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;
  IF nullif(btrim(p_grn_number),'') IS NULL OR nullif(btrim(p_correlation_id),'') IS NULL THEN
    RAISE EXCEPTION 'GRN number and correlation id are required';
  END IF;
  SELECT * INTO v_receipt FROM public.b2b_inventory_receipts
    WHERE id=p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.status NOT IN ('accepted','partially_accepted','rejected') THEN
    RAISE EXCEPTION 'Receipt is not ready for GRN';
  END IF;
  IF NOT public.can_access_b2b_inventory_store(v_actor,v_receipt.destination_store_code,'manage') THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_putaway_tasks t
    JOIN public.b2b_inventory_receipt_lines l ON l.id=t.receipt_line_id
    WHERE l.receipt_id=p_receipt_id AND t.status<>'completed') THEN
    RAISE EXCEPTION 'Every put-away task must be completed';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_receipt_lines l
    WHERE l.receipt_id=p_receipt_id AND l.accepted_qty>0 AND NOT EXISTS (
      SELECT 1 FROM public.b2b_inventory_putaway_tasks t
      WHERE t.receipt_line_id=l.id AND t.disposition='accepted' AND t.status='completed')) THEN
    RAISE EXCEPTION 'Every accepted quantity requires completed put-away';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_receipt_lines l
    WHERE l.receipt_id=p_receipt_id AND
      coalesce((SELECT sum(t.allocated_qty) FROM public.b2b_inventory_putaway_tasks t
        WHERE t.receipt_line_id=l.id AND t.disposition='accepted'),0)<>l.accepted_qty) THEN
    RAISE EXCEPTION 'Put-away does not reconcile with accepted quantity';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_grns
    WHERE receipt_id=p_receipt_id AND status IN ('draft','finalised')) THEN
    RAISE EXCEPTION 'Receipt already has an open GRN';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_grns
    WHERE receipt_id=p_receipt_id AND stock_posted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Receipt stock has already been posted';
  END IF;

  INSERT INTO public.b2b_inventory_grns(
    grn_number,receipt_id,status,finalised_by,finalised_at,correlation_id,
    stock_posted_at,stock_posted_by
  ) VALUES (btrim(p_grn_number),p_receipt_id,'finalised',v_actor,now(),p_correlation_id,now(),v_actor)
  RETURNING * INTO v_grn;

  FOR v_group IN
    SELECT product_id, sku, sum(accepted_qty) AS qty
    FROM public.b2b_inventory_receipt_lines
    WHERE receipt_id=p_receipt_id AND accepted_qty>0
    GROUP BY product_id,sku
  LOOP
    UPDATE public.inventory_stock_balances
    SET available_qty=available_qty+v_group.qty, version=version+1, updated_at=now()
    WHERE product_id=v_group.product_id AND sku=v_group.sku
      AND location_code=v_receipt.destination_store_code;
    IF NOT FOUND THEN RAISE EXCEPTION 'Held stock balance missing at GRN finalisation'; END IF;
  END LOOP;

  FOR v_line IN SELECT * FROM public.b2b_inventory_receipt_lines
    WHERE receipt_id=p_receipt_id AND accepted_qty>0 ORDER BY id
  LOOP
    INSERT INTO public.inventory_movements(
      movement_type,product_id,sku,quantity,destination_location,actor_id,
      reason_code,correlation_id,source_document_type,source_document_reference,
      batch_lot,expiry_date,metadata
    ) VALUES (
      'inventory_unhold',v_line.product_id,v_line.sku,v_line.accepted_qty,
      v_receipt.destination_store_code,v_actor,'grn_finalised',
      p_correlation_id || ':stock-post:' || v_line.id,
      v_receipt.source_document_type,v_receipt.source_document_reference,
      coalesce(v_line.oasis_batch_lot,v_line.supplier_batch_lot),v_line.expiry_date,
      jsonb_build_object('grn_id',v_grn.id,'grn_number',v_grn.grn_number,
        'receipt_id',p_receipt_id,'receipt_line_id',v_line.id)
    );
  END LOOP;
  RETURN v_grn;
END $$;

CREATE OR REPLACE FUNCTION public.resolve_b2b_supplier_discrepancy(
  p_discrepancy_id uuid, p_resolution text, p_status text DEFAULT 'resolved'
) RETURNS public.b2b_supplier_discrepancies
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid:=auth.uid(); v_row public.b2b_supplier_discrepancies%ROWTYPE; v_store text;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_b2b_inventory(v_actor) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;
  IF p_status NOT IN ('supplier_contacted','awaiting_credit','replacement_due','resolved','waived')
     OR nullif(btrim(p_resolution),'') IS NULL THEN RAISE EXCEPTION 'Valid status and resolution are required'; END IF;
  SELECT r.destination_store_code INTO v_store FROM public.b2b_supplier_discrepancies d
    JOIN public.b2b_inventory_receipt_lines l ON l.id=d.receipt_line_id
    JOIN public.b2b_inventory_receipts r ON r.id=l.receipt_id WHERE d.id=p_discrepancy_id;
  IF v_store IS NULL OR NOT public.can_access_b2b_inventory_store(v_actor,v_store,'manage') THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;
  UPDATE public.b2b_supplier_discrepancies SET status=p_status,resolution=btrim(p_resolution),
    resolved_by=CASE WHEN p_status IN ('resolved','waived') THEN v_actor ELSE NULL END,
    resolved_at=CASE WHEN p_status IN ('resolved','waived') THEN now() ELSE NULL END,updated_at=now()
  WHERE id=p_discrepancy_id AND status NOT IN ('resolved','waived') RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'Open discrepancy not found'; END IF;
  RETURN v_row;
END $$;

CREATE OR REPLACE FUNCTION public.reverse_b2b_inventory_grn(
  p_grn_id uuid, p_reversal_number text, p_reason text, p_correlation_id text
) RETURNS public.b2b_inventory_grns
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid:=auth.uid(); v_original public.b2b_inventory_grns%ROWTYPE;
 v_reversal public.b2b_inventory_grns%ROWTYPE; v_receipt public.b2b_inventory_receipts%ROWTYPE;
 v_group record; v_line public.b2b_inventory_receipt_lines%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_b2b_inventory(v_actor) THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501'; END IF;
  IF nullif(btrim(p_reversal_number),'') IS NULL OR nullif(btrim(p_reason),'') IS NULL OR nullif(btrim(p_correlation_id),'') IS NULL THEN RAISE EXCEPTION 'Reversal number, reason and correlation id are required'; END IF;
  SELECT * INTO v_original FROM public.b2b_inventory_grns WHERE id=p_grn_id FOR UPDATE;
  IF NOT FOUND OR v_original.status<>'finalised' THEN RAISE EXCEPTION 'Finalised GRN not found'; END IF;
  SELECT * INTO v_receipt FROM public.b2b_inventory_receipts WHERE id=v_original.receipt_id;
  IF NOT public.can_access_b2b_inventory_store(v_actor,v_receipt.destination_store_code,'manage') THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;
  FOR v_group IN SELECT product_id,sku,sum(accepted_qty) qty FROM public.b2b_inventory_receipt_lines WHERE receipt_id=v_receipt.id AND accepted_qty>0 GROUP BY product_id,sku LOOP
    UPDATE public.inventory_stock_balances SET available_qty=available_qty-v_group.qty,version=version+1,updated_at=now()
    WHERE product_id=v_group.product_id AND sku=v_group.sku AND location_code=v_receipt.destination_store_code AND available_qty>=v_group.qty;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient available stock for GRN reversal'; END IF;
  END LOOP;
  UPDATE public.b2b_inventory_grns SET status='reversed',reversal_reason=btrim(p_reason)
    WHERE id=v_original.id;
  INSERT INTO public.b2b_inventory_grns(grn_number,receipt_id,status,finalised_by,finalised_at,reversal_grn_id,reversal_reason,correlation_id,stock_posted_at,stock_posted_by)
  VALUES(btrim(p_reversal_number),v_receipt.id,'reversed',v_actor,now(),v_original.id,btrim(p_reason),p_correlation_id,now(),v_actor) RETURNING * INTO v_reversal;
  FOR v_line IN SELECT * FROM public.b2b_inventory_receipt_lines WHERE receipt_id=v_receipt.id AND accepted_qty>0 ORDER BY id LOOP
    INSERT INTO public.inventory_movements(movement_type,product_id,sku,quantity,source_location,actor_id,reason_code,correlation_id,source_document_type,source_document_reference,batch_lot,expiry_date,metadata)
    VALUES('correction_out',v_line.product_id,v_line.sku,v_line.accepted_qty,v_receipt.destination_store_code,v_actor,'grn_reversal',p_correlation_id||':'||v_line.id,v_receipt.source_document_type,v_receipt.source_document_reference,coalesce(v_line.oasis_batch_lot,v_line.supplier_batch_lot),v_line.expiry_date,jsonb_build_object('original_grn_id',v_original.id,'reversal_grn_id',v_reversal.id,'reason',p_reason));
  END LOOP;
  RETURN v_reversal;
END $$;

CREATE OR REPLACE VIEW public.b2b_gate_store_reconciliation
WITH (security_invoker=true) AS
SELECT r.id AS receipt_id,r.receipt_number,r.status AS receipt_status,r.created_at,
  r.received_at,g.grn_number,g.status AS grn_status,g.finalised_at,
  count(DISTINCT t.id) AS putaway_task_count,
  count(DISTINCT t.id) FILTER (WHERE t.status<>'completed') AS open_putaway_tasks,
  count(DISTINCT d.id) FILTER (WHERE d.status NOT IN ('resolved','waived')) AS open_discrepancies,
  CASE WHEN r.received_at IS NULL THEN 'awaiting_receipt'
       WHEN count(DISTINCT t.id) FILTER (WHERE t.status<>'completed')>0 THEN 'putaway_pending'
       WHEN g.status='reversed' THEN 'grn_reversed'
       WHEN g.id IS NULL THEN 'grn_pending'
       WHEN count(DISTINCT d.id) FILTER (WHERE d.status NOT IN ('resolved','waived'))>0 THEN 'discrepancy_open'
       ELSE 'reconciled' END AS reconciliation_status
FROM public.b2b_inventory_receipts r
LEFT JOIN public.b2b_inventory_receipt_lines l ON l.receipt_id=r.id
LEFT JOIN public.b2b_inventory_putaway_tasks t ON t.receipt_line_id=l.id
LEFT JOIN public.b2b_supplier_discrepancies d ON d.receipt_line_id=l.id
LEFT JOIN public.b2b_inventory_grns g ON g.receipt_id=r.id AND g.reversal_grn_id IS NULL
GROUP BY r.id,r.receipt_number,r.status,r.created_at,r.received_at,g.id,g.grn_number,g.status,g.finalised_at;

REVOKE ALL ON FUNCTION public.accept_b2b_inventory_receipt_phase3_posting(uuid,jsonb,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.accept_b2b_inventory_receipt(uuid,jsonb,text),public.finalise_b2b_inventory_grn(uuid,text,text),public.resolve_b2b_supplier_discrepancy(uuid,text,text),public.reverse_b2b_inventory_grn(uuid,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.accept_b2b_inventory_receipt(uuid,jsonb,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalise_b2b_inventory_grn(uuid,text,text),public.resolve_b2b_supplier_discrepancy(uuid,text,text),public.reverse_b2b_inventory_grn(uuid,text,text,text) TO authenticated;
REVOKE ALL ON public.b2b_gate_store_reconciliation FROM PUBLIC,anon;
GRANT SELECT ON public.b2b_gate_store_reconciliation TO authenticated;

COMMENT ON VIEW public.b2b_gate_store_reconciliation IS 'Gate-to-store ageing and closure state derived from receipt, put-away, GRN and discrepancy evidence.';
