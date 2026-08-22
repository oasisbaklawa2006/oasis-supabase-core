-- 3PGS STORE/EXECUTION surface: Central's ThirdPartyStore.tsx ("/admin/3pcs-store")
-- currently marks a 3PCS order_items row complete via a direct client UPDATE plus a
-- direct audit_logs insert, with no role gate beyond order_items' broad legacy grants
-- and no protection against completing the same row from a stale/duplicate click.
-- This adds a governed, idempotent completion RPC for that one action.
--
-- Scope note: order_items' broad legacy UPDATE grant for authenticated is NOT
-- revoked here. At least 10 other live Central admin screens update order_items
-- directly for unrelated fields/flows outside this programme segment's scope
-- (order intake is one of the two commercial bookends the owner directed not to
-- redesign yet). Revoking UPDATE wholesale would break those features. This RPC
-- is therefore an additive, governed path specifically for the 3PGS
-- store-execution completion action -- the Central 3PGS store-execution screen
-- is wired to call it instead of writing directly, for idempotency, role-gating
-- and an audit trail on that one action. A full order_items grant lockdown, if
-- ever undertaken, is a separate, much larger initiative requiring every other
-- caller to be migrated to governed RPCs first.

CREATE OR REPLACE FUNCTION public.complete_3pgs_order_item(
  p_order_item_id uuid,
  p_actual_packed_qty integer DEFAULT NULL
)
RETURNS public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_item public.order_items%ROWTYPE;
  v_packed integer;
BEGIN
  IF v_actor_id IS NULL OR public.is_internal_staff(v_actor_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised to complete a 3PGS order item' USING ERRCODE = '42501';
  END IF;

  IF p_order_item_id IS NULL THEN
    RAISE EXCEPTION 'An order item id is required';
  END IF;

  SELECT * INTO v_item FROM public.order_items WHERE id = p_order_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order item % not found', p_order_item_id;
  END IF;

  IF v_item.department IS DISTINCT FROM '3PCS' THEN
    RAISE EXCEPTION 'Order item % is not a 3PCS department item', p_order_item_id;
  END IF;

  -- Idempotent replay: a retried completion call on an already-completed item
  -- is a safe no-op, not an error.
  IF v_item.production_status = 'completed' THEN
    RETURN v_item;
  END IF;

  IF v_item.production_status IS DISTINCT FROM 'pending'
     AND v_item.production_status IS DISTINCT FROM 'in_progress'
     AND v_item.production_status IS DISTINCT FROM 'partial_ready' THEN
    RAISE EXCEPTION 'Order item % cannot be completed from status %', p_order_item_id, v_item.production_status;
  END IF;

  v_packed := coalesce(p_actual_packed_qty, v_item.quantity::integer);
  IF v_packed < 0 THEN
    RAISE EXCEPTION 'Actual packed quantity cannot be negative';
  END IF;

  UPDATE public.order_items
  SET production_status = 'completed',
      actual_packed_qty = v_packed
  WHERE id = p_order_item_id
  RETURNING * INTO v_item;

  INSERT INTO public.audit_logs (action_type, module_name, entity_name, entity_id, actor_id, risk_level)
  VALUES ('3PCS_COMPLETE', '3PCS', 'order_items', p_order_item_id::text, v_actor_id, 'normal');

  RETURN v_item;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_3pgs_order_item(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_3pgs_order_item(uuid, integer) TO authenticated;
