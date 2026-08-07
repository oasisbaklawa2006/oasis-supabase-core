-- Unannounced B2B customer return arrival — narrow service-recovery contract.
-- Conditional receipt protects the customer relationship without accepting
-- liability, a commercial claim, finance adjustment or usable inventory.

CREATE TABLE IF NOT EXISTS public.b2b_return_arrival_cases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_number text NOT NULL UNIQUE,
  customer_id uuid NULL,
  order_id uuid NULL REFERENCES public.orders (id) ON DELETE RESTRICT,
  original_consignment_id uuid NULL REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  arrival_state text NOT NULL DEFAULT 'awaiting_gate_decision',
  commercial_state text NOT NULL DEFAULT 'not_accepted',
  inventory_state text NOT NULL DEFAULT 'quarantine_only',
  stated_reason text NULL,
  transporter_name text NULL,
  driver_name text NULL,
  vehicle_number text NULL,
  tracking_lr_awb text NULL,
  cartons_presented integer NOT NULL CHECK (cartons_presented > 0),
  cartons_conditionally_received integer NOT NULL DEFAULT 0 CHECK (cartons_conditionally_received >= 0),
  external_condition text NOT NULL,
  gate_evidence_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
  transporter_ack_ref text NULL,
  transporter_ack_refused boolean NOT NULL DEFAULT false,
  refusal_witness_ref text NULL,
  quarantine_location text NULL,
  arrived_at timestamptz NOT NULL DEFAULT now(),
  gate_recorded_by uuid NULL,
  unloading_authorised_by uuid NULL,
  client_owner_id uuid NULL,
  qa_owner_id uuid NULL,
  operations_owner_id uuid NULL,
  finance_owner_id uuid NULL,
  final_disposition text NULL,
  final_decision_by uuid NULL,
  final_decision_at timestamptz NULL,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_return_arrival_state_check CHECK (arrival_state IN (
    'awaiting_gate_decision', 'vehicle_held', 'conditionally_received',
    'partially_received', 'quarantined', 'under_investigation',
    'commercially_decided', 'closed', 'rejected_at_gate'
  )),
  CONSTRAINT b2b_return_commercial_state_check CHECK (commercial_state IN (
    'not_accepted', 'under_review', 'claim_rejected', 'approved_return',
    'partial_return', 'goodwill_only', 'replacement_approved',
    'credit_approved', 'refund_approved'
  )),
  CONSTRAINT b2b_return_inventory_state_check CHECK (inventory_state IN (
    'quarantine_only', 'qa_hold', 'approved_rework', 'approved_disposal',
    'return_to_customer', 'closed_no_stock'
  )),
  CONSTRAINT b2b_return_carton_reconcile_check CHECK (
    cartons_conditionally_received <= cartons_presented
  ),
  CONSTRAINT b2b_return_receipt_evidence_check CHECK (
    arrival_state NOT IN ('conditionally_received', 'partially_received', 'quarantined')
    OR (
      jsonb_array_length(gate_evidence_refs) > 0
      AND unloading_authorised_by IS NOT NULL
      AND quarantine_location IS NOT NULL
      AND (transporter_ack_ref IS NOT NULL OR (transporter_ack_refused AND refusal_witness_ref IS NOT NULL))
    )
  ),
  CONSTRAINT b2b_return_closed_decision_check CHECK (
    arrival_state <> 'closed'
    OR (final_disposition IS NOT NULL AND final_decision_by IS NOT NULL AND final_decision_at IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS public.b2b_return_arrival_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_case_id uuid NOT NULL REFERENCES public.b2b_return_arrival_cases (id) ON DELETE RESTRICT,
  product_id uuid NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  product_code text NULL,
  batch_lot text NULL,
  expiry_date date NULL,
  quantity_presented numeric NOT NULL CHECK (quantity_presented > 0),
  quantity_verified numeric NOT NULL DEFAULT 0 CHECK (quantity_verified >= 0),
  qa_state text NOT NULL DEFAULT 'not_inspected',
  seal_state text NULL,
  temperature_state text NULL,
  evidence_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
  qa_findings text NULL,
  inspected_by uuid NULL,
  inspected_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_return_item_quantity_check CHECK (quantity_verified <= quantity_presented),
  CONSTRAINT b2b_return_item_qa_state_check CHECK (qa_state IN (
    'not_inspected', 'inspection_hold', 'substantiated_quality_return',
    'rework_candidate', 'disposal_required', 'laboratory_hold',
    'claim_unsubstantiated', 'return_to_customer'
  ))
);

CREATE TABLE IF NOT EXISTS public.b2b_return_arrival_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_case_id uuid NOT NULL REFERENCES public.b2b_return_arrival_cases (id) ON DELETE RESTRICT,
  decision_type text NOT NULL,
  decision_reason text NOT NULL,
  authority_role text NOT NULL,
  decided_by uuid NOT NULL,
  evidence_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
  supersedes_decision_id uuid NULL REFERENCES public.b2b_return_arrival_decisions (id) ON DELETE RESTRICT,
  decided_at timestamptz NOT NULL DEFAULT now(),
  correlation_id text NOT NULL UNIQUE,
  CONSTRAINT b2b_return_decision_type_check CHECK (decision_type IN (
    'conditional_quarantine_receipt', 'reject_at_gate', 'hold_for_clarification',
    'claim_rejected', 'full_replacement', 'partial_replacement',
    'full_credit', 'partial_credit', 'refund', 'goodwill_without_admission',
    'approved_rework', 'approved_disposal', 'return_to_customer', 'close_case'
  ))
);

CREATE INDEX IF NOT EXISTS idx_b2b_return_arrival_queue
  ON public.b2b_return_arrival_cases (arrival_state, arrived_at);

CREATE OR REPLACE FUNCTION public.prevent_b2b_return_arrival_delete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Return-arrival evidence is retained; supersede decisions and close the case';
END;
$$;

CREATE OR REPLACE FUNCTION public.protect_b2b_return_receipt_evidence()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.cartons_conditionally_received > 0 AND (
    NEW.cartons_conditionally_received < OLD.cartons_conditionally_received
    OR jsonb_array_length(NEW.gate_evidence_refs) = 0
    OR NEW.unloading_authorised_by IS NULL
    OR NEW.quarantine_location IS NULL
    OR (
      NEW.transporter_ack_ref IS NULL
      AND NOT (NEW.transporter_ack_refused AND NEW.refusal_witness_ref IS NOT NULL)
    )
  ) THEN
    RAISE EXCEPTION 'Conditional-return receipt evidence is retained once goods enter quarantine';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_b2b_return_decision_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Return-arrival decisions are immutable; add a superseding decision';
END;
$$;

CREATE OR REPLACE TRIGGER protect_conditional_receipt_evidence
  BEFORE UPDATE ON public.b2b_return_arrival_cases
  FOR EACH ROW EXECUTE FUNCTION public.protect_b2b_return_receipt_evidence();

CREATE OR REPLACE TRIGGER prevent_decision_update
  BEFORE UPDATE ON public.b2b_return_arrival_decisions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_return_decision_update();

DO $$
DECLARE relation_name text;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'b2b_return_arrival_cases', 'b2b_return_arrival_items', 'b2b_return_arrival_decisions'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS prevent_delete ON public.%I', relation_name);
    EXECUTE format(
      'CREATE TRIGGER prevent_delete BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_return_arrival_delete()',
      relation_name
    );
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', relation_name);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM anon', relation_name);
  END LOOP;
END;
$$;

-- Read is role-scoped. Mutations remain server/RPC-controlled until the
-- governed gate, QA, commercial and finance commands are introduced.
DROP POLICY IF EXISTS "Authorised staff read return arrivals" ON public.b2b_return_arrival_cases;
DROP POLICY IF EXISTS "Authorised staff read return items" ON public.b2b_return_arrival_items;
DROP POLICY IF EXISTS "Authorised staff read return decisions" ON public.b2b_return_arrival_decisions;
CREATE POLICY "Authorised staff read return arrivals"
  ON public.b2b_return_arrival_cases FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
CREATE POLICY "Authorised staff read return items"
  ON public.b2b_return_arrival_items FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
CREATE POLICY "Authorised staff read return decisions"
  ON public.b2b_return_arrival_decisions FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

COMMENT ON TABLE public.b2b_return_arrival_cases IS
  'Conditional gate receipt only: does not admit liability, validate quantity/quality, approve refund/replacement/credit, reverse an invoice, or create usable inventory.';
