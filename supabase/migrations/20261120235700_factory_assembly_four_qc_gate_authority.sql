-- Factory F28: four separate evidence-backed QC approvals on the *existing*
-- P&A assembly job. This is NOT a second assembly/BOM/stock workflow.
-- New authority is initially uncommissioned to preserve existing CI fixtures
-- and prevent accidental production interruption before physical QA/UAT.
-- Final go-live requires owner approval and a protected configuration migration.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE IF NOT EXISTS public.assembly_qc_commissioning_v1 (
  id boolean PRIMARY KEY DEFAULT true CHECK (id = true),
  enforced boolean NOT NULL DEFAULT false,
  policy_version text NULL,
  changed_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  changed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.assembly_qc_commissioning_v1(id,enforced)
VALUES(true,false) ON CONFLICT(id) DO NOTHING;
ALTER TABLE public.assembly_qc_commissioning_v1 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Internal staff can read Assembly QC commissioning" ON public.assembly_qc_commissioning_v1;
CREATE POLICY "Internal staff can read Assembly QC commissioning" ON public.assembly_qc_commissioning_v1
 FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));
REVOKE ALL ON public.assembly_qc_commissioning_v1 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.assembly_qc_commissioning_v1 TO authenticated;
-- Service-role configuration/deployment is separately privileged and audited.

CREATE TABLE IF NOT EXISTS public.assembly_qc_gate_events_v1 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_seq bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  assembly_job_id uuid NOT NULL REFERENCES public.b2b_assembly_jobs(id) ON DELETE RESTRICT,
  gate text NOT NULL CHECK (gate IN ('INPUT_MATERIAL','FIRST_PIECE','IN_PROCESS','FINAL')),
  decision text NOT NULL CHECK (decision IN ('PASS','FAIL','HOLD')),
  sample_qty numeric NOT NULL CHECK (sample_qty > 0),
  evidence_reference text NOT NULL CHECK (length(btrim(evidence_reference)) > 0),
  reason text NULL,
  inspected_by uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  correlation_id text NOT NULL UNIQUE,
  reservation_signature text NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.assembly_qc_gate_events_v1
 ADD COLUMN IF NOT EXISTS reservation_signature text NULL;
CREATE INDEX IF NOT EXISTS idx_assembly_qc_job_gate_latest
 ON public.assembly_qc_gate_events_v1(assembly_job_id,gate,event_seq DESC);
ALTER TABLE public.assembly_qc_gate_events_v1 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Internal staff can read Assembly QC" ON public.assembly_qc_gate_events_v1;
CREATE POLICY "Internal staff can read Assembly QC" ON public.assembly_qc_gate_events_v1
 FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));
REVOKE ALL ON public.assembly_qc_gate_events_v1 FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.assembly_qc_gate_events_v1 TO authenticated;
GRANT SELECT ON public.assembly_qc_gate_events_v1 TO service_role;
-- Intentionally no INSERT, UPDATE, DELETE grants: all recording is through RPC.

CREATE OR REPLACE FUNCTION public.assembly_qc_reservation_signature_v1(p_assembly_job_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $function$
  SELECT md5(
    coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'component_id',c.id,'product_id',c.product_id,'sku',c.sku,
        'source_store_code',c.source_store_code,'required_qty',c.required_qty,
        'reserved_qty',c.reserved_qty,'issued_qty',c.issued_qty
      ) ORDER BY c.id)::text
      FROM public.b2b_assembly_components c
      WHERE c.assembly_job_id=p_assembly_job_id
    ),'[]') || '|' || coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'assembly_component_id',i.assembly_component_id,
        'lot_position_id',i.lot_position_id,'issued_qty',i.issued_qty,
        'returned_qty',i.returned_qty
      ) ORDER BY i.assembly_component_id,i.lot_position_id,i.issue_correlation_id)::text
      FROM public.b2b_assembly_component_lot_issues i
      JOIN public.b2b_assembly_components c ON c.id=i.assembly_component_id
      WHERE c.assembly_job_id=p_assembly_job_id
    ),'[]')
  );
$function$;
REVOKE ALL ON FUNCTION public.assembly_qc_reservation_signature_v1(uuid)
 FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.assert_assembly_qc_sequence_v1(
 p_assembly_job_id uuid, p_through_gate text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_gate text;
  v_latest public.assembly_qc_gate_events_v1%ROWTYPE;
  v_prev_seq bigint := 0;
BEGIN
  IF p_through_gate NOT IN ('INPUT_MATERIAL','FIRST_PIECE','IN_PROCESS','FINAL') THEN
    RAISE EXCEPTION 'Unknown Assembly QC gate %', p_through_gate USING ERRCODE='23514';
  END IF;
  FOREACH v_gate IN ARRAY ARRAY['INPUT_MATERIAL','FIRST_PIECE','IN_PROCESS','FINAL'] LOOP
    SELECT * INTO v_latest FROM public.assembly_qc_gate_events_v1
    WHERE assembly_job_id=p_assembly_job_id AND gate=v_gate
    ORDER BY event_seq DESC LIMIT 1;
    IF NOT FOUND OR v_latest.decision IS DISTINCT FROM 'PASS'
      OR v_latest.event_seq <= v_prev_seq
    THEN
      RAISE EXCEPTION 'ASSEMBLY_QC_GATE_REQUIRED_OR_FAILED: %', v_gate USING ERRCODE='55000';
    END IF;
    IF v_gate='INPUT_MATERIAL'
      AND v_latest.reservation_signature IS DISTINCT FROM
          public.assembly_qc_reservation_signature_v1(p_assembly_job_id)
    THEN
      RAISE EXCEPTION 'ASSEMBLY_INPUT_QC_RESERVATION_CHANGED' USING ERRCODE='55000';
    END IF;
    v_prev_seq := v_latest.event_seq;
    EXIT WHEN v_gate=p_through_gate;
  END LOOP;
END;
$function$;
REVOKE ALL ON FUNCTION public.assert_assembly_qc_sequence_v1(uuid,text)
 FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.record_assembly_qc_gate_v1(
  p_assembly_job_id uuid,
  p_gate text,
  p_decision text,
  p_sample_qty numeric,
  p_evidence_reference text,
  p_reason text,
  p_correlation_id text
) RETURNS public.assembly_qc_gate_events_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_role text;
  v_job public.b2b_assembly_jobs%ROWTYPE;
  v_existing public.assembly_qc_gate_events_v1%ROWTYPE;
  v_gate text := upper(btrim(coalesce(p_gate,'')));
  v_decision text := upper(btrim(coalesce(p_decision,'')));
  v_reservation_signature text;
BEGIN
  SELECT upper(coalesce(role,'')) INTO v_role FROM public.users
  WHERE id=v_actor AND is_active IS TRUE;
  IF v_actor IS NULL OR v_role IS NULL OR v_role NOT IN (
    'SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER',
    'HOD_ASSEMBLY','PACKING_SUPERVISOR'
  ) THEN
    RAISE EXCEPTION 'ASSEMBLY_QC_REVIEWER_NOT_AUTHORIZED' USING ERRCODE='42501';
  END IF;
  IF nullif(btrim(p_correlation_id),'') IS NULL THEN
    RAISE EXCEPTION 'Assembly QC correlation id is required' USING ERRCODE='22023';
  END IF;
  IF v_gate NOT IN ('INPUT_MATERIAL','FIRST_PIECE','IN_PROCESS','FINAL')
    OR v_decision NOT IN ('PASS','FAIL','HOLD')
    OR p_sample_qty IS NULL OR p_sample_qty <= 0
    OR nullif(btrim(coalesce(p_evidence_reference,'')),'') IS NULL
  THEN
    RAISE EXCEPTION 'ASSEMBLY_QC_EVIDENCE_INVALID' USING ERRCODE='22023';
  END IF;
  IF v_decision IN ('FAIL','HOLD') AND nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN
    RAISE EXCEPTION 'ASSEMBLY_QC_FAILURE_REASON_REQUIRED' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs
  WHERE id=p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found' USING ERRCODE='22023'; END IF;
  v_reservation_signature := public.assembly_qc_reservation_signature_v1(p_assembly_job_id);

  SELECT * INTO v_existing FROM public.assembly_qc_gate_events_v1
  WHERE correlation_id=p_correlation_id;
  IF FOUND THEN
    IF v_existing.assembly_job_id <> p_assembly_job_id
      OR v_existing.gate <> v_gate OR v_existing.decision <> v_decision
      OR v_existing.sample_qty <> p_sample_qty
      OR v_existing.evidence_reference <> btrim(p_evidence_reference)
      OR (v_gate='INPUT_MATERIAL'
          AND v_existing.reservation_signature IS DISTINCT FROM v_reservation_signature)
      -- A repeated correlation must not silently discard a changed failure
      -- reason (or an added reason) from the immutable QC audit event.
      OR v_existing.reason IS DISTINCT FROM nullif(btrim(coalesce(p_reason,'')),'')
      OR v_existing.inspected_by <> v_actor
    THEN
      RAISE EXCEPTION 'ASSEMBLY_QC_IDEMPOTENCY_PAYLOAD_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN v_existing;
  END IF;
  IF v_gate='INPUT_MATERIAL' THEN
    IF v_job.status NOT IN ('materials_reserved','partially_reserved') THEN
      RAISE EXCEPTION 'Input QC requires reserved assembly materials';
    END IF;
  ELSIF v_gate IN ('FIRST_PIECE','IN_PROCESS') THEN
    IF v_job.status <> 'in_progress' THEN
      RAISE EXCEPTION 'First-piece/in-process QC requires work in progress';
    END IF;
    IF v_gate='FIRST_PIECE' THEN
      PERFORM public.assert_assembly_qc_sequence_v1(p_assembly_job_id,'INPUT_MATERIAL');
    ELSE
      PERFORM public.assert_assembly_qc_sequence_v1(p_assembly_job_id,'FIRST_PIECE');
    END IF;
  ELSE
    IF v_job.status <> 'qc_pending' THEN
      RAISE EXCEPTION 'Final QC requires completed assembly awaiting approval';
    END IF;
    PERFORM public.assert_assembly_qc_sequence_v1(p_assembly_job_id,'IN_PROCESS');
    -- The floor-completion actor is mandatory evidence of independence:
    -- NULL cannot prove that the final reviewer is a different person.
    IF v_decision='PASS'
      AND (v_job.completed_by IS NULL OR v_job.completed_by=v_actor) THEN
      RAISE EXCEPTION 'ASSEMBLY_FINAL_QC_MUST_HAVE_INDEPENDENT_REVIEWER' USING ERRCODE='42501';
    END IF;
  END IF;

  INSERT INTO public.assembly_qc_gate_events_v1(
    assembly_job_id,gate,decision,sample_qty,evidence_reference,
    reason,inspected_by,correlation_id,reservation_signature
  ) VALUES (
    p_assembly_job_id,v_gate,v_decision,p_sample_qty,btrim(p_evidence_reference),
    nullif(btrim(coalesce(p_reason,'')),''),v_actor,p_correlation_id,
    CASE WHEN v_gate='INPUT_MATERIAL' THEN v_reservation_signature ELSE NULL END
  ) RETURNING * INTO v_existing;
  RETURN v_existing;
END;
$function$;
REVOKE ALL ON FUNCTION public.record_assembly_qc_gate_v1(uuid,text,text,numeric,text,text,text)
 FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.record_assembly_qc_gate_v1(uuid,text,text,numeric,text,text,text)
 TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_assembly_four_qc_gates_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_enabled boolean := false;
  v_last_final public.assembly_qc_gate_events_v1%ROWTYPE;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  SELECT enforced INTO v_enabled FROM public.assembly_qc_commissioning_v1 WHERE id=true;
  IF coalesce(v_enabled,false) IS NOT TRUE THEN RETURN NEW; END IF;

  IF NEW.status='issued' THEN
    PERFORM public.assert_assembly_qc_sequence_v1(NEW.id,'INPUT_MATERIAL');
  ELSIF NEW.status='qc_pending' THEN
    PERFORM public.assert_assembly_qc_sequence_v1(NEW.id,'IN_PROCESS');
  ELSIF NEW.status IN ('accepted','partially_accepted') THEN
    PERFORM public.assert_assembly_qc_sequence_v1(NEW.id,'FINAL');
  ELSIF NEW.status='rejected' AND OLD.status='qc_pending' THEN
    SELECT * INTO v_last_final FROM public.assembly_qc_gate_events_v1
    WHERE assembly_job_id=NEW.id AND gate='FINAL'
    ORDER BY event_seq DESC LIMIT 1;
    IF NOT FOUND OR v_last_final.decision NOT IN ('FAIL','HOLD') THEN
      RAISE EXCEPTION 'ASSEMBLY_FINAL_QC_REJECTION_EVIDENCE_REQUIRED' USING ERRCODE='55000';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.guard_assembly_four_qc_gates_v1()
 FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS trg_assembly_four_qc_gates ON public.b2b_assembly_jobs;
CREATE TRIGGER trg_assembly_four_qc_gates
 BEFORE UPDATE OF status ON public.b2b_assembly_jobs
 FOR EACH ROW EXECUTE FUNCTION public.guard_assembly_four_qc_gates_v1();

CREATE OR REPLACE FUNCTION public.guard_assembly_qc_positive_consumption_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_enabled boolean := false;
  v_blocked_gate text;
BEGIN
  SELECT enforced INTO v_enabled FROM public.assembly_qc_commissioning_v1 WHERE id=true;
  IF coalesce(v_enabled,false) IS NOT TRUE THEN RETURN NEW; END IF;

  IF coalesce(NEW.consumed_qty,0) <= coalesce(OLD.consumed_qty,0)
     AND coalesce(NEW.wasted_qty,0) <= coalesce(OLD.wasted_qty,0)
  THEN
    RETURN NEW;
  END IF;

  SELECT gate INTO v_blocked_gate
  FROM (
    SELECT DISTINCT ON (gate) gate, decision
    FROM public.assembly_qc_gate_events_v1
    WHERE assembly_job_id=NEW.assembly_job_id
      AND gate IN ('INPUT_MATERIAL','FIRST_PIECE','IN_PROCESS','FINAL')
    ORDER BY gate,event_seq DESC
  ) latest
  WHERE decision IN ('FAIL','HOLD')
  ORDER BY gate LIMIT 1;

  IF v_blocked_gate IS NOT NULL THEN
    RAISE EXCEPTION 'ASSEMBLY_QC_CONSUMPTION_BLOCKED: %', v_blocked_gate USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.guard_assembly_qc_positive_consumption_v1()
 FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS trg_assembly_qc_positive_consumption ON public.b2b_assembly_components;
CREATE TRIGGER trg_assembly_qc_positive_consumption
 BEFORE INSERT OR UPDATE OF consumed_qty,wasted_qty ON public.b2b_assembly_components
 FOR EACH ROW EXECUTE FUNCTION public.guard_assembly_qc_positive_consumption_v1();

COMMENT ON TABLE public.assembly_qc_commissioning_v1 IS
 'Explicit protected Factory commissioning gate. Must not be enabled until Owner policy, isolated UAT and Central QC UI are approved.';
COMMENT ON TABLE public.assembly_qc_gate_events_v1 IS
 'Append-only four-gate Packing & Assembly QC evidence, bound to existing b2b_assembly_jobs, most recent event per stage authoritative.';
