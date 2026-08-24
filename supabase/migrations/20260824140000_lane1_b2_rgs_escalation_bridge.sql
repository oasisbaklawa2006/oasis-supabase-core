-- Lane 1 B2 (Central issue #368): RGS support/escalation routing.
--
-- Same audit finding as 20260822160000_production_issue_resolution_and_escalation.sql
-- (Production), now confirmed for RGS: the existing CMD War Room / Execution
-- Command Center escalation topology (buildEscalationTopology(), Central
-- src/lib/execution-intelligence/escalationTopology.ts) already buckets
-- ANY operational_events row by actor_department when its event_type
-- contains "escalat"/"failed" -- it needs no RGS-specific branch. The gap is
-- that nothing has ever called append_operational_event_v1() for an RGS
-- handover sitting unacknowledged. RGS's own day-end signoff
-- (submit_production_day_end, 20260822170000) already identifies exactly
-- this condition server-side for its own summary --
-- handovers_awaiting_rgs_acknowledgement: production_rgs_transfers rows
-- whose status is not yet a terminal one. This migration reuses that exact
-- clause to actually emit the event, rather than only surfacing it once a
-- day inside a signoff summary.
--
-- Deliberately NOT a new escalation mechanism, NOT a cron job (no scheduler
-- infrastructure exists in this repo for that), and NOT a rewrite of the
-- RGS lifecycle RPCs (reserve_rgs_stock, dispatch_production_to_rgs,
-- record_rgs_receipt, etc. are untouched). Instead: one read-mostly,
-- idempotent RPC that the RGS admin screen (Central's ReadyGoodsStore.tsx)
-- calls on load -- the same "plug into the existing bus from real usage"
-- pattern report_production_issue() established for Production.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.emit_rgs_handover_escalations()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_emitted integer := 0;
  v_row record;
  v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL OR public.is_internal_staff(v_actor_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  FOR v_row IN
    SELECT prt.id, prt.job_id, prt.quantity, prt.status, prt.created_at,
           pj.canonical_department, pj.priority
    FROM public.production_rgs_transfers prt
    LEFT JOIN public.production_jobs pj ON pj.id = prt.job_id
    WHERE prt.status NOT IN ('accepted', 'rejected', 'cancelled')
  LOOP
    PERFORM public.append_operational_event_v1(
      p_event_type := 'rgs_handover_escalation',
      p_entity_type := 'production_rgs_transfer',
      p_entity_id := v_row.id,
      p_title := 'RGS handover awaiting acknowledgement (' || coalesce(v_row.canonical_department, 'unknown') || ')',
      p_source_application := 'rgs',
      p_correlation_id := 'rgs-handover-escalation:' || v_row.id::text,
      p_actor_department := 'RGS',
      p_severity := CASE WHEN v_row.priority IN ('urgent', 'red') THEN 'urgent' ELSE 'warning' END,
      p_message := 'Transfer ' || v_row.id::text || ' has been ' || v_row.status || ' since ' || v_row.created_at::text || ' without RGS acceptance or rejection.',
      p_idempotency_key := 'rgs-handover-escalation:' || v_row.id::text || ':' || v_row.status
    );
    v_emitted := v_emitted + 1;
  END LOOP;

  RETURN v_emitted;
END;
$$;

COMMENT ON FUNCTION public.emit_rgs_handover_escalations() IS
  'Scans production_rgs_transfers for handovers still awaiting RGS acknowledgement (same clause as submit_production_day_end''s handovers_awaiting_rgs_acknowledgement) and appends an rgs_handover_escalation operational_event per one, idempotent per (transfer, status) so it surfaces exactly once per state in the existing CMD War Room / Execution Command Center escalation topology. Returns the count emitted this call. Internal staff only.';

REVOKE ALL ON FUNCTION public.emit_rgs_handover_escalations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emit_rgs_handover_escalations() TO authenticated;
