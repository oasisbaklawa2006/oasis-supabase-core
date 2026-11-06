-- Governed production completion for non-3PCS order items (additive, forward-only; ASM CP17 Task 2).
-- Closes the CP16 gap: release_order_to_packed_ready_v1 trusted order_items.production_status/actual_packed_qty, which
-- for every product except 3PCS were written by direct table updates with no production evidence. This migration:
--   1. adds complete_order_item_from_production_v1: only the mark_packed_ready authority may call it; the packed
--      quantity is DERIVED from the governed pipeline (production_jobs bound to the order line, completed, whose
--      production_rgs_transfers were accepted by RGS receiving = the QC/stock acceptance) and never exceeds the
--      ordered quantity, so rejected/held/short quantities cannot count and re-runs cannot inflate;
--   2. records every completion as an immutable, idempotent event (order_item_production_completions);
--   3. adds an evidence policy (observe by default, enforce only by a separately approved change): in observe mode
--      release_order_to_packed_ready_v1 audits a packed-ready claim that has no governed completion; in enforce mode
--      it blocks it. Existing direct writes are NOT prohibited here, so Central screens keep working during rollout.
-- rollback-plan: restore release_order_to_packed_ready_v1 from 20260809070000, then drop
-- complete_order_item_from_production_v1, order_production_evidence_policy and order_item_production_completions
-- (completion events are audit evidence; export before dropping). order_items rows already completed stay as they are.

CREATE TABLE IF NOT EXISTS public.order_item_production_completions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id uuid NOT NULL REFERENCES public.order_items(id),
  order_id uuid NOT NULL,
  product_id uuid,
  ordered_qty numeric NOT NULL,
  packed_qty numeric NOT NULL CHECK (packed_qty >= 0),
  outcome text NOT NULL CHECK (outcome IN ('PARTIAL','COMPLETE')),
  evidence jsonb NOT NULL,
  actor_id uuid NOT NULL,
  actor_role text,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE INDEX IF NOT EXISTS order_item_production_completions_item_idx
  ON public.order_item_production_completions(order_item_id, created_at DESC);
ALTER TABLE public.order_item_production_completions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.order_item_production_completions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.order_item_production_completions TO authenticated, service_role;
DROP POLICY IF EXISTS order_item_production_completions_internal_read ON public.order_item_production_completions;
CREATE POLICY order_item_production_completions_internal_read ON public.order_item_production_completions
  FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.prevent_order_item_production_completion_mutation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'ORDER_ITEM_PRODUCTION_COMPLETIONS_APPEND_ONLY' USING ERRCODE = '42501';
END;
$$;
REVOKE ALL ON FUNCTION public.prevent_order_item_production_completion_mutation() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS trg_order_item_production_completions_immutable ON public.order_item_production_completions;
CREATE TRIGGER trg_order_item_production_completions_immutable
  BEFORE UPDATE OR DELETE ON public.order_item_production_completions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_order_item_production_completion_mutation();

CREATE TABLE IF NOT EXISTS public.order_production_evidence_policy (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  enforce_packed_ready boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
INSERT INTO public.order_production_evidence_policy(id, enforce_packed_ready) VALUES (true, false) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.order_production_evidence_policy ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.order_production_evidence_policy FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.order_production_evidence_policy TO authenticated, service_role;
DROP POLICY IF EXISTS order_production_evidence_policy_internal_read ON public.order_production_evidence_policy;
CREATE POLICY order_production_evidence_policy_internal_read ON public.order_production_evidence_policy
  FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.complete_order_item_from_production_v1(
  p_order_item_id uuid,
  p_correlation_id text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_corr text := btrim(coalesce(p_correlation_id, ''));
  v_item public.order_items%rowtype;
  v_prior public.order_item_production_completions%rowtype;
  v_last public.order_item_production_completions%rowtype;
  v_same_product int;
  v_jobs int;
  v_job_ids uuid[];
  v_transfer_ids uuid[];
  v_accepted numeric;
  v_pack numeric;
  v_outcome text;
  v_role text;
  v_evidence jsonb;
BEGIN
  PERFORM public.assert_order_transition_role('mark_packed_ready');
  IF p_order_item_id IS NULL OR v_corr = '' THEN
    RAISE EXCEPTION 'ORDER_ITEM_COMPLETION_INVALID: order item and correlation id are required' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_item FROM public.order_items WHERE id = p_order_item_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('order-item-production:' || p_order_item_id::text, 0));

  SELECT * INTO v_prior FROM public.order_item_production_completions WHERE correlation_id = v_corr;
  IF FOUND THEN
    IF v_prior.order_item_id IS DISTINCT FROM p_order_item_id THEN
      RAISE EXCEPTION 'ORDER_ITEM_COMPLETION_CORRELATION_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN jsonb_build_object('ok', true, 'order_item_id', p_order_item_id, 'packed_qty', v_prior.packed_qty,
                              'outcome', v_prior.outcome, 'already_recorded', true);
  END IF;

  IF coalesce(v_item.department, '') = '3PCS' THEN
    RAISE EXCEPTION 'ORDER_ITEM_USE_3PGS_COMPLETION: 3PCS items complete through complete_3pgs_order_item' USING ERRCODE = '55000';
  END IF;
  IF v_item.order_id IS NULL OR v_item.product_id IS NULL OR coalesce(v_item.quantity, 0) <= 0 THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_COMPLETABLE' USING ERRCODE = '55000';
  END IF;
  IF v_item.quantity <> trunc(v_item.quantity) THEN
    RAISE EXCEPTION 'ORDER_ITEM_QUANTITY_NOT_INTEGRAL: actual_packed_qty is an integer column' USING ERRCODE = '55000';
  END IF;

  -- Bind evidence to this order line: jobs carry order_item_id; legacy jobs without it bind by order + product only
  -- when this is the only line of that product on the order (otherwise attribution would be ambiguous).
  SELECT count(*) INTO v_same_product FROM public.order_items o
   WHERE o.order_id = v_item.order_id AND o.product_id = v_item.product_id;
  SELECT array_agg(j.id), count(*) INTO v_job_ids, v_jobs
    FROM public.production_jobs j
   WHERE j.status = 'completed'
     AND (j.order_item_id = v_item.id
          OR (j.order_item_id IS NULL AND j.order_id = v_item.order_id AND j.product_id = v_item.product_id AND v_same_product = 1));
  IF coalesce(v_jobs, 0) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEM_NO_PRODUCTION_EVIDENCE: no completed production job is bound to this order line' USING ERRCODE = '55000';
  END IF;
  SELECT coalesce(sum(t.accepted_qty), 0), array_agg(t.id) INTO v_accepted, v_transfer_ids
    FROM public.production_rgs_transfers t
   WHERE t.job_id = ANY (v_job_ids) AND t.status IN ('accepted', 'partially_accepted') AND t.accepted_qty IS NOT NULL;
  IF v_accepted <= 0 THEN
    RAISE EXCEPTION 'ORDER_ITEM_NO_ACCEPTED_STOCK: production is not yet accepted by RGS receiving (QC/stock control)' USING ERRCODE = '55000';
  END IF;

  v_pack := least(v_item.quantity, v_accepted);
  v_outcome := CASE WHEN v_pack >= v_item.quantity THEN 'COMPLETE' ELSE 'PARTIAL' END;
  SELECT * INTO v_last FROM public.order_item_production_completions
   WHERE order_item_id = p_order_item_id ORDER BY created_at DESC, id DESC LIMIT 1;
  IF FOUND AND v_pack <= v_last.packed_qty THEN
    RETURN jsonb_build_object('ok', true, 'order_item_id', p_order_item_id, 'packed_qty', v_last.packed_qty,
                              'outcome', v_last.outcome, 'already_current', true);
  END IF;

  v_role := upper(coalesce(public.get_user_role(auth.uid()), ''));
  v_evidence := jsonb_build_object(
    'job_ids', to_jsonb(v_job_ids), 'transfer_ids', to_jsonb(v_transfer_ids),
    'accepted_qty_total', v_accepted, 'ordered_qty', v_item.quantity, 'derived_packed_qty', v_pack);
  INSERT INTO public.order_item_production_completions(
    order_item_id, order_id, product_id, ordered_qty, packed_qty, outcome, evidence, actor_id, actor_role, correlation_id
  ) VALUES (
    v_item.id, v_item.order_id, v_item.product_id, v_item.quantity, v_pack, v_outcome, v_evidence, auth.uid(), v_role, v_corr);
  UPDATE public.order_items
     SET production_status = CASE WHEN v_outcome = 'COMPLETE' THEN 'completed' ELSE 'partial_ready' END,
         actual_packed_qty = v_pack::integer
   WHERE id = v_item.id;
  INSERT INTO public.audit_logs(action_type, module_name, entity_name, entity_id, actor_id, risk_level, new_value)
  VALUES (CASE WHEN v_outcome = 'COMPLETE' THEN 'ORDER_ITEM_PRODUCTION_COMPLETED' ELSE 'ORDER_ITEM_PRODUCTION_PARTIAL' END,
          'Operations', 'order_items', v_item.id::text, auth.uid(), 'high', v_evidence);
  RETURN jsonb_build_object('ok', true, 'order_item_id', v_item.id, 'packed_qty', v_pack, 'outcome', v_outcome,
                            'already_recorded', false, 'evidence', v_evidence);
END;
$$;
REVOKE ALL ON FUNCTION public.complete_order_item_from_production_v1(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.complete_order_item_from_production_v1(uuid, text) TO authenticated;

create or replace function public.release_order_to_packed_ready_v1(p_order_id uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.orders%rowtype; v_open int; v_unsupported int; v_enforce boolean;
begin
 perform public.assert_order_transition_role('mark_packed_ready'); select * into v from public.orders where id=p_order_id for update;
 if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); end if;
 if v.status='packed_ready' then return jsonb_build_object('ok',true,'order_id',p_order_id,'already_applied',true); end if;
 if v.status not in('in_production','manufacturing','assembled','packing','partial_ready') then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_status'))); end if;
 select count(*) into v_open from public.order_items where order_id=p_order_id and (lower(coalesce(production_status,'')) not in('completed','partial_ready') or coalesce(actual_packed_qty,0)<coalesce(quantity,0));
 if v_open>0 then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','packing_incomplete','lines',v_open))); end if;
 -- Production-evidence policy (CP17): items other than 3PCS (which has its own governed completion) must have a
 -- governed production completion. Observe mode records the gap; enforce mode (separately approved) blocks it.
 select count(*) into v_unsupported from public.order_items oi
  where oi.order_id=p_order_id and coalesce(oi.department,'')<>'3PCS'
    and not exists(select 1 from public.order_item_production_completions c where c.order_item_id=oi.id and c.packed_qty>=oi.quantity);
 select coalesce((select enforce_packed_ready from public.order_production_evidence_policy limit 1),false) into v_enforce;
 if v_unsupported>0 and v_enforce then
   return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','production_completion_unsupported','lines',v_unsupported)));
 end if;
 if v_unsupported>0 then
   insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value)
   values('PACKED_READY_WITHOUT_GOVERNED_PRODUCTION_EVIDENCE','Operations','orders',p_order_id::text,auth.uid(),'high',jsonb_build_object('unsupported_lines',v_unsupported));
 end if;
 update public.orders set status='packed_ready' where id=p_order_id;
 insert into public.order_status_history(order_id,old_status,new_status,changed_by) values(p_order_id,v.status,'packed_ready',auth.uid());
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level) values('ORDER_MARKED_PACKED_READY','Operations','orders',p_order_id::text,auth.uid(),'high');
 return jsonb_build_object('ok',true,'order_id',p_order_id,'already_applied',false);
end $$;

revoke all on function public.release_order_to_packed_ready_v1(uuid) from public,anon;
grant execute on function public.release_order_to_packed_ready_v1(uuid) to authenticated,service_role;
