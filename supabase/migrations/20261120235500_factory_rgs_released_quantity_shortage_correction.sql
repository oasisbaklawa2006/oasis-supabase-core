-- Factory F09: release_rgs_reservation already decrements reserved_qty.
-- released_qty records historical movement; subtracting it again causes phantom
-- shortage coverage and can suppress valid production requirements.
-- Reuse the existing Core reservation, production_jobs and correlation guards.
-- No stock movement or legacy data backfill occurs in this migration.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.create_production_shortage_demand(
  p_reservation_id uuid, p_department text, p_priority text, p_correlation_id text
) RETURNS public.production_jobs
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor_id uuid := auth.uid();
  v_reservation public.inventory_reservations%ROWTYPE;
  v_canonical_department text;
  v_shortage numeric;
  v_job public.production_jobs%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_inventory_manage_role(
    (SELECT role FROM public.users WHERE id = v_actor_id)
  ) THEN
    RAISE EXCEPTION 'Not authorised to create production shortage demand' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  v_canonical_department := public.canonical_production_department(p_department);
  IF v_canonical_department IS NULL THEN
    RAISE EXCEPTION 'Unknown production department %', p_department;
  END IF;

  SELECT * INTO v_reservation
  FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF v_reservation.reservation_status NOT IN ('pending', 'partially_reserved', 'reserved') THEN
    RAISE EXCEPTION 'Reservation % is not eligible for production-shortage routing', p_reservation_id;
  END IF;

  -- A previous partial release reduces reserved_qty already. released_qty is
  -- history, not an additional current cover for this demand.
  v_shortage := v_reservation.requested_qty - v_reservation.reserved_qty
                - v_reservation.fulfilled_qty;
  IF v_shortage <= 0 THEN
    RAISE EXCEPTION 'Reservation % has no shortage to route to production', p_reservation_id;
  END IF;

  -- Keep the existing one-open-job-per-reservation+department authority.
  SELECT * INTO v_job
  FROM public.production_jobs
  WHERE reservation_id = p_reservation_id
    AND canonical_department = v_canonical_department
    AND status NOT IN ('rejected', 'completed', 'transferred');
  IF FOUND THEN RETURN v_job; END IF;

  INSERT INTO public.production_jobs (
    order_id, product_id, department, reservation_id, requested_by, assigned_qty,
    priority, status, stage, correlation_id
  ) VALUES (
    v_reservation.order_id, v_reservation.product_id, v_canonical_department,
    p_reservation_id, v_actor_id, v_shortage, coalesce(p_priority, 'normal'),
    'pending', 'prep', p_correlation_id
  ) RETURNING * INTO v_job;
  RETURN v_job;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_production_shortage_demand(uuid,text,text,text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_production_shortage_demand(uuid,text,text,text) TO authenticated;

COMMENT ON FUNCTION public.create_production_shortage_demand(uuid,text,text,text)
IS 'F09: remaining shortage = requested - currently reserved - fulfilled; historical released_qty never subtracts twice. Terminal reservations blocked; existing job idempotency retained.';
