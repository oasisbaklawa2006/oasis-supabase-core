-- Phase 4: governed put-away, GRN finalisation and stock-inward posting.
-- Accepted receipt quantities are location-controlled and GRNs are immutable.

CREATE TABLE public.b2b_inventory_bins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_code text NOT NULL REFERENCES public.b2b_inventory_stores(store_code),
  zone_code text NOT NULL,
  rack_code text NOT NULL,
  shelf_code text NOT NULL,
  bin_code text NOT NULL,
  capacity_qty numeric NULL CHECK (capacity_qty IS NULL OR capacity_qty > 0),
  storage_class text NOT NULL DEFAULT 'ambient' CHECK (storage_class IN ('ambient','chilled','frozen','quarantine','damaged','rejected','return_to_vendor')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_code, bin_code)
);

CREATE TABLE public.b2b_inventory_putaway_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_line_id uuid NOT NULL REFERENCES public.b2b_inventory_receipt_lines(id) ON DELETE RESTRICT,
  bin_id uuid NOT NULL REFERENCES public.b2b_inventory_bins(id) ON DELETE RESTRICT,
  disposition text NOT NULL CHECK (disposition IN ('accepted','qc_hold','damaged','rejected','return_to_vendor')),
  allocated_qty numeric NOT NULL CHECK (allocated_qty > 0),
  placed_qty numeric NOT NULL DEFAULT 0 CHECK (placed_qty >= 0 AND placed_qty <= allocated_qty),
  status text NOT NULL DEFAULT 'allocated' CHECK (status IN ('allocated','in_progress','completed','exception')),
  assigned_to uuid NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  completed_by uuid NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  completed_at timestamptz NULL,
  exception_reason text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (receipt_line_id, bin_id, disposition)
);
CREATE INDEX idx_b2b_putaway_tasks_status ON public.b2b_inventory_putaway_tasks(status, created_at);

CREATE TABLE public.b2b_inventory_grns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  grn_number text NOT NULL UNIQUE,
  receipt_id uuid NOT NULL UNIQUE REFERENCES public.b2b_inventory_receipts(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','finalised','reversed')),
  finalised_by uuid NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  finalised_at timestamptz NULL,
  reversal_grn_id uuid NULL REFERENCES public.b2b_inventory_grns(id) ON DELETE RESTRICT,
  reversal_reason text NULL,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.b2b_supplier_discrepancies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_line_id uuid NOT NULL REFERENCES public.b2b_inventory_receipt_lines(id) ON DELETE RESTRICT,
  discrepancy_type text NOT NULL CHECK (discrepancy_type IN ('short','excess','damaged','rejected','wrong_item','wrong_batch','expiry','barcode','document','quality','weight','commercial')),
  quantity numeric NULL CHECK (quantity IS NULL OR quantity >= 0),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','supplier_contacted','awaiting_credit','replacement_due','resolved','waived')),
  owner_id uuid NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  resolution text NULL,
  resolved_by uuid NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  resolved_at timestamptz NULL,
  evidence jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_b2b_supplier_discrepancies_queue ON public.b2b_supplier_discrepancies(status, created_at);

ALTER TABLE public.b2b_inventory_bins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.b2b_inventory_putaway_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.b2b_inventory_grns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.b2b_supplier_discrepancies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Internal staff read Phase 4 bins" ON public.b2b_inventory_bins FOR SELECT TO authenticated USING (public.is_internal_staff((select auth.uid())));
CREATE POLICY "Internal staff read Phase 4 tasks" ON public.b2b_inventory_putaway_tasks FOR SELECT TO authenticated USING (public.is_internal_staff((select auth.uid())));
CREATE POLICY "Internal staff read Phase 4 GRNs" ON public.b2b_inventory_grns FOR SELECT TO authenticated USING (public.is_internal_staff((select auth.uid())));
CREATE POLICY "Internal staff read Phase 4 discrepancies" ON public.b2b_supplier_discrepancies FOR SELECT TO authenticated USING (public.is_internal_staff((select auth.uid())));

REVOKE ALL ON public.b2b_inventory_bins, public.b2b_inventory_putaway_tasks, public.b2b_inventory_grns, public.b2b_supplier_discrepancies FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_inventory_bins, public.b2b_inventory_putaway_tasks, public.b2b_inventory_grns, public.b2b_supplier_discrepancies FROM authenticated;
GRANT SELECT ON public.b2b_inventory_bins, public.b2b_inventory_putaway_tasks, public.b2b_inventory_grns, public.b2b_supplier_discrepancies TO authenticated;

CREATE OR REPLACE FUNCTION public.allocate_b2b_inventory_putaway(p_receipt_id uuid, p_allocations jsonb, p_correlation_id text)
RETURNS SETOF public.b2b_inventory_putaway_tasks
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid := auth.uid(); v_item jsonb; v_line public.b2b_inventory_receipt_lines%ROWTYPE; v_bin public.b2b_inventory_bins%ROWTYPE; v_qty numeric; v_disposition text;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_b2b_inventory(v_actor) THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501'; END IF;
  IF jsonb_typeof(p_allocations) <> 'array' OR jsonb_array_length(p_allocations)=0 OR nullif(btrim(p_correlation_id),'') IS NULL THEN RAISE EXCEPTION 'Allocations and correlation id are required'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
    SELECT * INTO STRICT v_line FROM public.b2b_inventory_receipt_lines WHERE id=(v_item->>'line_id')::uuid AND receipt_id=p_receipt_id FOR UPDATE;
    SELECT * INTO STRICT v_bin FROM public.b2b_inventory_bins WHERE id=(v_item->>'bin_id')::uuid AND active FOR UPDATE;
    v_qty := (v_item->>'quantity')::numeric; v_disposition := v_item->>'disposition';
    IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'Allocation quantity must be positive'; END IF;
    IF (v_disposition='accepted' AND v_bin.storage_class IN ('quarantine','damaged','rejected','return_to_vendor')) OR (v_disposition<>'accepted' AND v_bin.storage_class='ambient') THEN RAISE EXCEPTION 'Disposition and bin storage class mismatch'; END IF;
    INSERT INTO public.b2b_inventory_putaway_tasks(receipt_line_id,bin_id,disposition,allocated_qty,assigned_to)
    VALUES(v_line.id,v_bin.id,v_disposition,v_qty,(v_item->>'assigned_to')::uuid)
    ON CONFLICT (receipt_line_id,bin_id,disposition) DO UPDATE
      SET allocated_qty=EXCLUDED.allocated_qty, assigned_to=EXCLUDED.assigned_to, updated_at=now();
  END LOOP;
  IF EXISTS (
    SELECT 1 FROM public.b2b_inventory_receipt_lines l
    WHERE l.receipt_id=p_receipt_id AND (
      coalesce((SELECT sum(t.allocated_qty) FROM public.b2b_inventory_putaway_tasks t WHERE t.receipt_line_id=l.id AND t.disposition='accepted'),0) <> l.accepted_qty
      OR coalesce((SELECT sum(t.allocated_qty) FROM public.b2b_inventory_putaway_tasks t WHERE t.receipt_line_id=l.id AND t.disposition='damaged'),0) <> l.damaged_qty
      OR coalesce((SELECT sum(t.allocated_qty) FROM public.b2b_inventory_putaway_tasks t WHERE t.receipt_line_id=l.id AND t.disposition='rejected'),0) <> l.rejected_qty
    )
  ) THEN RAISE EXCEPTION 'Put-away allocations must reconcile with every receipt disposition'; END IF;
  RETURN QUERY SELECT t.* FROM public.b2b_inventory_putaway_tasks t JOIN public.b2b_inventory_receipt_lines l ON l.id=t.receipt_line_id WHERE l.receipt_id=p_receipt_id ORDER BY t.created_at;
END $$;

CREATE OR REPLACE FUNCTION public.confirm_b2b_inventory_putaway(p_task_id uuid, p_bin_code text, p_quantity numeric, p_correlation_id text)
RETURNS public.b2b_inventory_putaway_tasks
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid := auth.uid(); v_task public.b2b_inventory_putaway_tasks%ROWTYPE; v_expected_bin text;
BEGIN
  IF v_actor IS NULL OR NOT public.can_receive_b2b_inventory(v_actor) THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501'; END IF;
  IF p_quantity <= 0 OR nullif(btrim(p_correlation_id),'') IS NULL THEN RAISE EXCEPTION 'Quantity and correlation id are required'; END IF;
  SELECT t.* INTO v_task FROM public.b2b_inventory_putaway_tasks t WHERE t.id=p_task_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Put-away task not found'; END IF;
  SELECT b.bin_code INTO v_expected_bin FROM public.b2b_inventory_bins b WHERE b.id=v_task.bin_id;
  IF v_expected_bin <> p_bin_code THEN RAISE EXCEPTION 'Scanned bin does not match allocation'; END IF;
  IF v_task.placed_qty + p_quantity > v_task.allocated_qty THEN RAISE EXCEPTION 'Placed quantity exceeds allocation'; END IF;
  UPDATE public.b2b_inventory_putaway_tasks SET placed_qty=placed_qty+p_quantity,status=CASE WHEN placed_qty+p_quantity=allocated_qty THEN 'completed' ELSE 'in_progress' END,completed_by=CASE WHEN placed_qty+p_quantity=allocated_qty THEN v_actor ELSE completed_by END,completed_at=CASE WHEN placed_qty+p_quantity=allocated_qty THEN now() ELSE completed_at END,updated_at=now() WHERE id=p_task_id RETURNING * INTO v_task;
  RETURN v_task;
END $$;

CREATE OR REPLACE FUNCTION public.finalise_b2b_inventory_grn(p_receipt_id uuid, p_grn_number text, p_correlation_id text)
RETURNS public.b2b_inventory_grns
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid:=auth.uid(); v_receipt public.b2b_inventory_receipts%ROWTYPE; v_grn public.b2b_inventory_grns%ROWTYPE; v_line record; v_existing numeric;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_b2b_inventory(v_actor) THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501'; END IF;
  IF nullif(btrim(p_grn_number),'') IS NULL OR nullif(btrim(p_correlation_id),'') IS NULL THEN RAISE EXCEPTION 'GRN number and correlation id are required'; END IF;
  SELECT * INTO v_receipt FROM public.b2b_inventory_receipts WHERE id=p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.status NOT IN ('accepted','partially_accepted','rejected') THEN RAISE EXCEPTION 'Receipt is not ready for GRN'; END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_putaway_tasks t JOIN public.b2b_inventory_receipt_lines l ON l.id=t.receipt_line_id WHERE l.receipt_id=p_receipt_id AND t.status<>'completed') THEN RAISE EXCEPTION 'Every put-away task must be completed'; END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_receipt_lines l WHERE l.receipt_id=p_receipt_id AND l.accepted_qty>0 AND NOT EXISTS (SELECT 1 FROM public.b2b_inventory_putaway_tasks t WHERE t.receipt_line_id=l.id AND t.disposition='accepted')) THEN RAISE EXCEPTION 'Every accepted quantity requires put-away'; END IF;
  INSERT INTO public.b2b_inventory_grns(grn_number,receipt_id,status,finalised_by,finalised_at,correlation_id) VALUES(btrim(p_grn_number),p_receipt_id,'finalised',v_actor,now(),p_correlation_id) RETURNING * INTO v_grn;
  RETURN v_grn;
END $$;

CREATE OR REPLACE FUNCTION public.prevent_phase4_delete() RETURNS trigger LANGUAGE plpgsql SET search_path='public' AS $$ BEGIN RAISE EXCEPTION 'Phase 4 records are immutable; use a governed reversal'; END $$;
CREATE TRIGGER trg_phase4_bins_no_delete BEFORE DELETE ON public.b2b_inventory_bins FOR EACH ROW EXECUTE FUNCTION public.prevent_phase4_delete();
CREATE TRIGGER trg_phase4_tasks_no_delete BEFORE DELETE ON public.b2b_inventory_putaway_tasks FOR EACH ROW EXECUTE FUNCTION public.prevent_phase4_delete();
CREATE TRIGGER trg_phase4_grns_no_delete BEFORE DELETE ON public.b2b_inventory_grns FOR EACH ROW EXECUTE FUNCTION public.prevent_phase4_delete();
CREATE TRIGGER trg_phase4_discrepancies_no_delete BEFORE DELETE ON public.b2b_supplier_discrepancies FOR EACH ROW EXECUTE FUNCTION public.prevent_phase4_delete();

REVOKE ALL ON FUNCTION public.allocate_b2b_inventory_putaway(uuid,jsonb,text), public.confirm_b2b_inventory_putaway(uuid,text,numeric,text), public.finalise_b2b_inventory_grn(uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_b2b_inventory_putaway(uuid,jsonb,text), public.confirm_b2b_inventory_putaway(uuid,text,numeric,text), public.finalise_b2b_inventory_grn(uuid,text,text) TO authenticated;

COMMENT ON TABLE public.b2b_inventory_putaway_tasks IS 'Scanner-confirmed physical placement; allocations must reconcile to receipt disposition quantities.';
COMMENT ON TABLE public.b2b_inventory_grns IS 'Immutable receipt-closing documents; reversal is represented by a linked GRN, never deletion.';
